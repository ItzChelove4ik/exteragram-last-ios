import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import PresentationDataUtils
import ContextUI
import ChatControllerInteraction
import OverlayStatusController
import ConvertOpusToAAC
import ExteraSpeech

// Immutable handoff into the main queue. AccountContext and interaction are
// accessed only by the @MainActor presentation; no audio crosses the network.
private final class ExteraSpeechMenuArguments: @unchecked Sendable {
    let context: AccountContext
    let message: EngineRawMessage
    let file: TelegramMediaFile
    let interaction: ChatControllerInteraction
    let locale: String

    init(context: AccountContext, message: EngineRawMessage, file: TelegramMediaFile, interaction: ChatControllerInteraction, locale: String) {
        self.context = context
        self.message = message
        self.file = file
        self.interaction = interaction
        self.locale = locale
    }
}

func exteraSpeechContextMenuItem(context: AccountContext, message: EngineRawMessage, controllerInteraction: ChatControllerInteraction, locale: String) -> ContextMenuItem? {
    guard message.minAutoremoveOrClearTimeout == nil, !message.containsSecretMedia, !message.isCopyProtected(),
          let file = message.effectiveMedia.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVoice || $0.isInstantVideo || $0.mimeType.lowercased().hasPrefix("audio/") }) else {
        return nil
    }
    let arguments = ExteraSpeechMenuArguments(context: context, message: message, file: file, interaction: controllerInteraction, locale: locale)
    let title = locale.lowercased().hasPrefix("ru") ? "Распознать на этом iPhone" : "Transcribe on this iPhone"
    return .action(ContextMenuActionItem(text: title, icon: { theme in
        generateTintedImage(image: UIImage(systemName: "text.bubble"), color: theme.contextMenu.primaryColor)
    }, action: { _, finish in
        finish(.default)
        DispatchQueue.main.async {
            ExteraSpeechPresentation.begin(arguments)
        }
    }))
}

@MainActor
private final class ExteraSpeechPresentation {
    private static var active: [UUID: ExteraSpeechPresentation] = [:]
    private let identifier = UUID()
    private let arguments: ExteraSpeechMenuArguments
    private let resource = MetaDisposable()
    private let conversion = MetaDisposable()
    private let transcriber = ExteraSpeechTranscriber()
    private var recognition: (any ExteraSpeechTask)?
    private var loading: ViewController?
    private var temporaryDirectory: URL?
    private var finished = false

    private init(_ arguments: ExteraSpeechMenuArguments) { self.arguments = arguments }

    static func begin(_ arguments: ExteraSpeechMenuArguments) {
        let operation = ExteraSpeechPresentation(arguments)
        active[operation.identifier] = operation
        operation.start()
    }

    private func start() {
        let presentationData = arguments.context.sharedContext.currentPresentationData.with { $0 }
        let loading = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: { [weak self] in self?.cancel() }))
        self.loading = loading
        arguments.interaction.presentControllerInCurrent(loading, nil)
        // Media must already be downloaded by Telegram. This action does not
        // request server transcription or fetch media through a new endpoint.
        resource.set((arguments.context.engine.resources.data(id: EngineMediaResource.Id(arguments.file.resource.id))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self, !self.finished else { return }
            guard data.isComplete else {
                self.finish(.failure(.fileNotFound))
                return
            }
            if self.arguments.file.isVoice || self.arguments.file.isInstantVideo || self.arguments.file.mimeType.lowercased().contains("ogg") {
                self.convert(path: data.path)
            } else {
                self.recognize(path: data.path)
            }
        }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, !self.finished, self.recognition == nil else { return }
            self.finish(.failure(.timedOut))
        }
    }

    private func convert(path: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExteraSpeech-" + identifier.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
            let outputPath = directory.appendingPathComponent("voice.m4a").path
            conversion.set((convertOpusToAAC(sourcePath: path, allocateTempFile: { outputPath })
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] converted in
                guard let self, !self.finished else { return }
                guard let converted else { self.finish(.failure(.invalidAudio)); return }
                self.recognize(path: converted)
            }))
        } catch {
            finish(.failure(.invalidAudio))
        }
    }

    private func recognize(path: String) {
        guard !finished else { return }
        recognition = transcriber.transcribe(fileURL: URL(fileURLWithPath: path), localeIdentifier: arguments.locale) { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func cancel() { finish(.failure(.cancelled)) }

    private func finish(_ result: Result<ExteraSpeechTranscript, ExteraSpeechError>) {
        guard !finished else { return }
        finished = true
        resource.dispose()
        conversion.dispose()
        recognition?.cancel()
        recognition = nil
        loading?.dismiss()
        loading = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        Self.active.removeValue(forKey: identifier)
        let presentationData = arguments.context.sharedContext.currentPresentationData.with { $0 }
        let russian = arguments.locale.lowercased().hasPrefix("ru")
        switch result {
        case let .success(transcript):
            let _ = arguments.context.engine.messages.storeLocallyTranscribedAudio(messageId: arguments.message.id, text: transcript.text, isFinal: true, error: nil).startStandalone()
            let alert = textAlertController(context: arguments.context, title: russian ? "Расшифровка" : "Transcription", text: transcript.text, actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_OK, action: {}),
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Conversation_ContextMenuCopy, action: { UIPasteboard.general.string = transcript.text })
            ])
            arguments.interaction.presentControllerInCurrent(alert, nil)
        case let .failure(error):
            if error == .cancelled { return }
            let message: String
            switch error {
            case .authorizationDenied, .authorizationRestricted:
                message = russian ? "Разрешите распознавание речи для приложения в настройках iPhone." : "Allow speech recognition for this app in iPhone Settings."
            case .unsupportedLocale, .onDeviceRecognitionUnavailable:
                message = russian ? "Для этого языка или устройства недоступно распознавание на iPhone. Аудио не отправлялось на сервер." : "On-device recognition is unavailable for this language or device. No audio was uploaded."
            case .fileNotFound:
                message = russian ? "Сначала скачайте аудио в чате." : "Download the audio in the chat first."
            case .timedOut:
                message = russian ? "Время распознавания истекло. Попробуйте более короткую запись." : "Transcription timed out. Try a shorter recording."
            case .noSpeech:
                message = russian ? "Речь не обнаружена." : "No speech was recognized."
            default:
                message = russian ? "Не удалось распознать этот аудиофайл на устройстве." : "This audio file could not be transcribed on this device."
            }
            arguments.interaction.presentControllerInCurrent(textAlertController(context: arguments.context, title: russian ? "Распознавание речи" : "Speech recognition", text: message, actions: [TextAlertAction(type: .genericAction, title: presentationData.strings.Common_OK, action: {})]), nil)
        }
    }
}

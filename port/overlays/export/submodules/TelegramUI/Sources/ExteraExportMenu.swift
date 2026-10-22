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
import ExteraExport

private final class ExteraExportMenuArguments: @unchecked Sendable {
    let context: AccountContext
    let message: EngineRawMessage
    let interaction: ChatControllerInteraction
    let russian: Bool
    let title: String
    init(context: AccountContext, message: EngineRawMessage, interaction: ChatControllerInteraction, locale: String, title: String) {
        self.context = context; self.message = message; self.interaction = interaction
        self.russian = locale.lowercased().hasPrefix("ru"); self.title = title
    }
}

func exteraExportContextMenuItem(context: AccountContext, message: EngineRawMessage, controllerInteraction: ChatControllerInteraction, locale: String) -> ContextMenuItem? {
    guard let peer = message.peers[message.id.peerId], !peer.isForumOrMonoForum,
          !peer.isCopyProtectionEnabled, !message.isCopyProtected(), !message.containsSecretMedia,
          message.id.peerId.namespace != Namespaces.Peer.SecretChat else { return nil }
    let arguments = ExteraExportMenuArguments(context: context, message: message, interaction: controllerInteraction, locale: locale, title: peer.debugDisplayTitle)
    return .action(ContextMenuActionItem(text: arguments.russian ? "Экспорт текста чата (HTML/JSON)" : "Export chat text (HTML/JSON)", icon: { theme in
        generateTintedImage(image: UIImage(systemName: "square.and.arrow.up"), color: theme.contextMenu.primaryColor)
    }, action: { _, finish in
        finish(.default)
        DispatchQueue.main.async { ExteraExportPresentation.confirm(arguments) }
    }))
}

@MainActor
private final class ExteraExportPresentation {
    private static var active: [UUID: ExteraExportPresentation] = [:]
    private let identifier = UUID()
    private let arguments: ExteraExportMenuArguments
    private let request = MetaDisposable()
    private var accumulator = ExteraExportAccumulator(maximumMessages: 100_000)
    private var loading: ViewController?
    private var finished = false
    private var requestGeneration = 0

    private init(_ arguments: ExteraExportMenuArguments) { self.arguments = arguments }

    static func confirm(_ arguments: ExteraExportMenuArguments) {
        let strings = arguments.context.sharedContext.currentPresentationData.with { $0 }.strings
        let text = arguments.russian
            ? "Будет прочитана вся доступная облачная история этого диалога и созданы HTML и JSON. Экспорт содержит текст и метаданные файлов без самих вложений. Не включает удалённые и временные сообщения, историю до миграции группы и другие аккаунты. Ограничения: 100 000 записей и 20 МиБ расчётного объёма текста и метаданных. При превышении лимита или ошибке полный экспорт не создаётся. Выберите «Сохранить в Файлы» в окне экспорта."
            : "Reads all available cloud history for this peer and creates HTML and JSON. Includes text and file metadata, without attachment binaries. Excludes deleted or ephemeral messages, history before a group migration and other accounts. Limits: 100,000 records and 20 MiB of estimated text and metadata content. Exceeding a limit or encountering an error does not produce a complete export. Choose Save to Files in the share sheet."
        let alert = textAlertController(context: arguments.context, title: arguments.russian ? "Экспорт переписки" : "Export chat history", text: text, actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: arguments.russian ? "Экспортировать" : "Export", action: {
                DispatchQueue.main.async {
                    let operation = ExteraExportPresentation(arguments)
                    Self.active[operation.identifier] = operation
                    operation.start()
                }
            })
        ])
        arguments.interaction.presentControllerInCurrent(alert, nil)
    }

    private func start() {
        let theme = arguments.context.sharedContext.currentPresentationData.with { $0 }.theme
        let loading = OverlayStatusController(theme: theme, type: .loading(cancelled: { [weak self] in self?.cancel() }))
        self.loading = loading
        arguments.interaction.presentControllerInCurrent(loading, nil)
        fetchNextPage()
    }

    private func fetchNextPage() {
        guard !finished else { return }
        requestGeneration += 1
        let generation = requestGeneration
        request.set((exteraExportCloudHistoryPage(account: arguments.context.account, peerId: arguments.message.id.peerId,
            offsetId: accumulator.offsetId, snapshotMaxMessageId: accumulator.snapshotMaxMessageId)
        |> take(1) |> deliverOnMainQueue).start(next: { [weak self] page in
            guard let self, !self.finished, self.requestGeneration == generation else { return }
            self.requestGeneration += 1
            do {
                try self.accumulator.append(page)
                if self.accumulator.completed { self.encodeFiles() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.fetchNextPage() } }
            } catch let error as ExteraExportError {
                if case let .tooManyMessages(limit) = error {
                    self.fail(self.arguments.russian ? "В истории больше \(limit) записей. Экспорт не завершён; файлы не созданы." : "History exceeds \(limit) records. Export is incomplete; no files were created.")
                } else if case .tooMuchContent = error {
                    self.fail(self.arguments.russian ? "Расчётный объём текста и метаданных превышает 20 МиБ. Экспорт не завершён; файлы не созданы." : "Estimated text and metadata content exceeds 20 MiB. Export is incomplete; no files were created.")
                } else { self.failIncomplete() }
            } catch { self.failIncomplete() }
        }, error: { [weak self] error in
            guard let self, !self.finished else { return }
            switch error {
            case .copyProtected:
                self.fail(self.arguments.russian ? "Для этого диалога включена защита содержимого. Экспорт остановлен." : "Content protection is enabled for this chat. Export stopped.")
            case .unsupportedPeer:
                self.fail(self.arguments.russian ? "Экспорт секретных чатов и форумов пока не поддерживается." : "Secret chats and forums are not supported by this export.")
            case let .requestFailed(description):
                if description.hasPrefix("FLOOD_WAIT") {
                    self.fail(self.arguments.russian ? "Telegram временно ограничил запросы. Экспорт не завершён; повторите позже." : "Telegram temporarily limited requests. Export is incomplete; try again later.")
                } else { self.failIncomplete() }
            default: self.failIncomplete()
            }
        }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.finished, self.requestGeneration == generation else { return }
            self.failIncomplete()
        }
    }

    private func encodeFiles() {
        do {
            let document = try accumulator.document(peerId: String(arguments.message.id.peerId.toInt64()), title: arguments.title)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExteraExport-" + identifier.uuidString, isDirectory: true)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try ExteraExportEncoder.json(document).write(to: directory.appendingPathComponent("result.json"), options: [.atomic, .completeFileProtection])
                    try Data(ExteraExportEncoder.html(document).utf8).write(to: directory.appendingPathComponent("messages.html"), options: [.atomic, .completeFileProtection])
                    DispatchQueue.main.async {
                        guard let self, !self.finished else { try? FileManager.default.removeItem(at: directory); return }
                        self.share(directory: directory)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    DispatchQueue.main.async { self?.failIncomplete() }
                }
            }
        } catch { failIncomplete() }
    }

    private func share(directory: URL) {
        finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [arguments] in
            guard let view = arguments.interaction.navigationController()?.view else {
                try? FileManager.default.removeItem(at: directory)
                Self.showError(arguments, text: arguments.russian ? "Не удалось открыть окно сохранения. Повторите экспорт." : "Could not open the share sheet. Retry the export.")
                return
            }
            let controller = UIActivityViewController(activityItems: [directory.appendingPathComponent("result.json"), directory.appendingPathComponent("messages.html")], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            controller.completionWithItemsHandler = { _, _, _, error in
                try? FileManager.default.removeItem(at: directory)
                if error != nil {
                    DispatchQueue.main.async { Self.showError(arguments, text: arguments.russian ? "Файлы не были сохранены выбранным приложением." : "The selected application could not save the export files.") }
                }
            }
            arguments.context.sharedContext.applicationBindings.presentNativeController(controller)
        }
    }

    private func cancel() { finish() }
    private func failIncomplete() {
        fail(arguments.russian ? "Не удалось получить всю историю или сохранить файлы. Экспорт не завершён; готовые файлы не созданы. Проверьте подключение и доступ к диалогу." : "Could not read all history or save the files. Export is incomplete; no completed files were created. Check your connection and access to this chat.")
    }
    private func fail(_ text: String) {
        guard !finished else { return }
        finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [arguments] in Self.showError(arguments, text: text) }
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        request.dispose()
        loading?.dismiss()
        loading = nil
        Self.active.removeValue(forKey: identifier)
    }
    private static func showError(_ arguments: ExteraExportMenuArguments, text: String) {
        let strings = arguments.context.sharedContext.currentPresentationData.with { $0 }.strings
        arguments.interaction.presentControllerInCurrent(textAlertController(context: arguments.context, title: arguments.russian ? "Экспорт переписки" : "Export chat history", text: text,
            actions: [TextAlertAction(type: .genericAction, title: strings.Common_OK, action: {})]), nil)
    }
}

import Foundation
import UIKit
import TelegramCore
import AccountContext
import SwiftSignalKit
import ExteraPreferences
import ExteraTranslation

/// Called from the real selected-message translation entry point. The service
/// receives only the text explicitly passed to this translation action.
public func presentExteraTranslation(context: AccountContext, text: String, entities: [MessageTextEntity], canCopy: Bool,
                              fromLanguage: String?, toLanguage: String?, provider: ExteraTranslationProvider,
                              replaceText: ((String, [MessageTextEntity]) -> Void)?, wasDismissed: (() -> Void)?) {
    guard let root = context.sharedContext.mainWindow?.viewController?.view.window?.rootViewController else {
        wasDismissed?()
        return
    }
    let appLanguage = context.sharedContext.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode
    let preferred = ExteraPreferences.standard.value(for: ExteraSettings.targetLang)
    let target = toLanguage ?? (preferred == "app" ? appLanguage : preferred)
    let controller = ExteraTranslateController(context: context, text: text, entities: entities, source: fromLanguage, target: target,
                                               appLanguage: appLanguage, provider: provider, canCopy: canCopy,
                                               replaceText: replaceText, wasDismissed: wasDismissed)
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    navigation.presentationController?.delegate = controller
    var presenter = root
    while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
    presenter.present(navigation, animated: true)
}

private final class ExteraTranslateController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let context: AccountContext
    private let original: String
    private let originalEntities: [MessageTextEntity]
    private let source: String?
    private var target: String
    private let appLanguage: String
    private let provider: ExteraTranslationProvider
    private let canCopy: Bool
    private let replaceText: ((String, [MessageTextEntity]) -> Void)?
    private var wasDismissed: (() -> Void)?
    private let client = ExteraTranslationClient()
    private var translationTask: Task<Void, Never>?
    private let translationDisposable = MetaDisposable()
    private var generation = 0
    private var translated: String?
    private var translatedEntities: [MessageTextEntity] = []
    private let output = UITextView()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let languageButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private var copyButton: UIBarButtonItem?
    private var replaceButton: UIBarButtonItem?

    init(context: AccountContext, text: String, entities: [MessageTextEntity], source: String?, target: String, appLanguage: String,
         provider: ExteraTranslationProvider, canCopy: Bool,
         replaceText: ((String, [MessageTextEntity]) -> Void)?, wasDismissed: (() -> Void)?) {
        self.context = context
        self.original = text
        self.originalEntities = entities
        self.source = source
        self.target = target
        self.appLanguage = appLanguage
        self.provider = provider
        self.canCopy = canCopy
        self.replaceText = replaceText
        self.wasDismissed = wasDismissed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        translationTask?.cancel()
        translationDisposable.dispose()
    }

    private var russian: Bool { appLanguage.lowercased().hasPrefix("ru") }
    private func label(_ en: String, _ ru: String) -> String { russian ? ru : en }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = label("Translation", "Перевод") + " · " + provider.displayName
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: label("Close", "Закрыть"), style: .plain,
                                                           target: self, action: #selector(close))
        var buttons: [UIBarButtonItem] = []
        if canCopy {
            let button = UIBarButtonItem(title: label("Copy", "Копировать"), style: .plain, target: self, action: #selector(copyTranslation))
            button.isEnabled = false
            copyButton = button
            buttons.append(button)
        }
        if replaceText != nil {
            let button = UIBarButtonItem(title: label("Replace", "Заменить"), style: .plain, target: self, action: #selector(replaceTranslation))
            button.isEnabled = false
            replaceButton = button
            buttons.append(button)
        }
        navigationItem.rightBarButtonItems = buttons
        output.isEditable = false
        output.isSelectable = canCopy
        output.font = UIFont.preferredFont(forTextStyle: .body)
        output.adjustsFontForContentSizeCategory = true
        output.backgroundColor = .clear
        output.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        languageButton.addTarget(self, action: #selector(selectLanguage), for: .touchUpInside)
        retryButton.setTitle(label("Try again", "Повторить"), for: .normal)
        retryButton.addTarget(self, action: #selector(startTranslation), for: .touchUpInside)
        retryButton.isHidden = true
        let status = UIStackView(arrangedSubviews: [languageButton, activity, retryButton])
        status.axis = .horizontal
        status.spacing = 12
        status.alignment = .center
        status.distribution = .fill
        status.translatesAutoresizingMaskIntoConstraints = false
        output.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        view.addSubview(output)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            output.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            output.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            output.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            output.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        startTranslation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { finish() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

    private func finish() {
        generation += 1
        translationTask?.cancel()
        translationTask = nil
        translationDisposable.set(nil)
        let callback = wasDismissed
        wasDismissed = nil
        callback?()
    }

    @objc private func close() {
        finish()
        dismiss(animated: true)
    }

    @objc private func copyTranslation() {
        guard canCopy, let translated else { return }
        UIPasteboard.general.string = translated
    }

    @objc private func replaceTranslation() {
        guard let translated else { return }
        // Telegram returns translated entities. External services are plain
        // text: original entity offsets must never be reused after translation.
        replaceText?(translated, translatedEntities)
        close()
    }

    private func normalized(_ value: String) -> String {
        var code = value.replacingOccurrences(of: "_", with: "-")
        if code.hasSuffix("-raw") { code = String(code.dropLast(4)) }
        if code.lowercased().hasPrefix("zh") {
            if provider == .yandex { return "zh" }
            return code.lowercased().contains("hant") || code.lowercased().contains("tw") ? "zh-TW" : "zh-CN"
        }
        return code
    }

    @objc private func startTranslation() {
        generation += 1
        let currentGeneration = generation
        translationTask?.cancel()
        translationDisposable.set(nil)
        let service = client
        let text = original
        let from = source.flatMap { $0.isEmpty ? nil : normalized($0) } ?? "auto"
        let to = normalized(target)
        let selectedProvider = provider
        let locale = Locale(identifier: appLanguage)
        languageButton.setTitle((locale.localizedString(forIdentifier: target) ?? target) + " ▾", for: .normal)
        retryButton.isHidden = true
        copyButton?.isEnabled = false
        replaceButton?.isEnabled = false
        translated = nil
        translatedEntities = []
        output.text = label("Translating…", "Перевод…")
        output.textColor = .secondaryLabel
        activity.startAnimating()
        if selectedProvider == .telegram {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                complete(text, entities: originalEntities)
                return
            }
            translationDisposable.set((context.engine.messages.translate(text: text, toLang: normalizeTranslationLanguage(to), entities: originalEntities)
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.generation == currentGeneration else { return }
                guard let result, !result.0.isEmpty else {
                    self.fail(self.errorMessage(ExteraTranslationError.invalidResponse))
                    return
                }
                self.complete(result.0, entities: result.1)
            }, error: { [weak self] error in
                guard let self, self.generation == currentGeneration else { return }
                switch error {
                case .limitExceeded:
                    self.fail(self.errorMessage(ExteraTranslationError.rateLimited(retryAfterSeconds: 0)))
                case .invalidLanguage:
                    self.fail(self.errorMessage(ExteraTranslationError.unsupportedLanguage))
                case .textTooLong:
                    self.fail(self.label("This text exceeds Telegram's translation limit.", "Текст превышает ограничение перевода Telegram."))
                case .tryAlternative:
                    self.fail(self.label("Telegram translation is unavailable for this request. Select another translator in GlowGram settings.", "Перевод Telegram недоступен для этого запроса. Выберите другой переводчик в настройках GlowGram."))
                default:
                    self.fail(self.errorMessage(ExteraTranslationError.invalidResponse))
                }
            }))
            return
        }
        translationTask = Task { @MainActor [weak self] in
            do {
                let result = try await service.translate(text, from: from, to: to, provider: selectedProvider)
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                self.complete(result, entities: [])
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                self.fail(self.errorMessage(error))
            }
        }
    }

    private func complete(_ text: String, entities: [MessageTextEntity]) {
        translated = text
        translatedEntities = entities
        output.text = text
        output.textColor = .label
        copyButton?.isEnabled = canCopy
        replaceButton?.isEnabled = replaceText != nil
        activity.stopAnimating()
    }

    private func fail(_ message: String) {
        activity.stopAnimating()
        output.text = message
        retryButton.isHidden = false
    }

    private func errorMessage(_ error: Error) -> String {
        guard russian else { return error.localizedDescription }
        switch error as? ExteraTranslationError {
        case .configurationRequired: return "Для этого переводчика нужен собственный ключ сервиса. Выберите Google или Yandex в настройках GlowGram."
        case .rateLimited: return "Переводчик временно ограничил запросы. Повторите позже."
        case .unsupportedLanguage, .invalidLanguage: return "Переводчик не поддерживает выбранный язык."
        default: return "Не удалось получить перевод. Проверьте подключение или выберите другой переводчик в настройках GlowGram."
        }
    }

    @objc private func selectLanguage() {
        let picker = UIAlertController(title: label("Translate to", "Язык перевода"), message: nil, preferredStyle: .actionSheet)
        let locale = Locale(identifier: appLanguage)
        let codes = [appLanguage, "ar", "de", "en", "es", "fa", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru", "tr", "uk", "uz", "vi", "zh-Hans", "zh-Hant"]
        var seen = Set<String>()
        for code in codes where seen.insert(normalized(code)).inserted {
            let name = locale.localizedString(forIdentifier: code) ?? code
            picker.addAction(UIAlertAction(title: name, style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.target = code
                try? ExteraPreferences.standard.set(code, for: ExteraSettings.targetLang)
                self.startTranslation()
            }))
        }
        picker.addAction(UIAlertAction(title: label("Cancel", "Отмена"), style: .cancel))
        picker.popoverPresentationController?.sourceView = languageButton
        picker.popoverPresentationController?.sourceRect = languageButton.bounds
        present(picker, animated: true)
    }
}

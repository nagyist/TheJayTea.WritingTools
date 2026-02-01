import SwiftUI
import Observation
import UniformTypeIdentifiers

private let logger = AppLogger.logger("AppState")

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var geminiProvider: GeminiProvider
    var openAIProvider: OpenAIProvider
    var mistralProvider: MistralProvider
    var anthropicProvider: AnthropicProvider
    var ollamaProvider: OllamaProvider
    var localLLMProvider: LocalModelProvider
    var openRouterProvider: OpenRouterProvider

    // Cache for providers with model overrides to prevent memory leaks
    // Key: "providerName:model" -> Provider instance
    @ObservationIgnored
    private var modelOverrideProviderCache: [String: any AIProvider] = [:]
    private let maxCacheSize = 10

    var customInstruction: String = ""
    var selectedText: String = ""
    var isPopupVisible: Bool = false
    var isProcessing: Bool = false
    var previousApplication: NSRunningApplication?
    var selectedImages: [Data] = []

    // Command management
    var commandManager = CommandManager()
    var customCommandsManager = CustomCommandsManager()

    // Current provider with UI binding support
    private(set) var currentProvider: String

    var selectedAttributedText: NSAttributedString? = nil

    var activeProvider: any AIProvider {
        switch currentProvider {
        case "openai":
            return openAIProvider
        case "gemini":
            return geminiProvider
        case "anthropic":
            return anthropicProvider
        case "ollama":
            return ollamaProvider
        case "mistral":
            return mistralProvider
        case "openrouter":
            return openRouterProvider
        default:
            return localLLMProvider
        }
    }

    // MARK: - Per-Command Provider Selection

    /// Get the appropriate provider for a command, respecting per-command overrides
    func getProvider(for command: CommandModel) -> any AIProvider {
        let providerName = command.providerOverride ?? currentProvider

        logger.debug("AppState.getProvider: command=\(command.name), providerOverride=\(command.providerOverride ?? "nil"), providerName=\(providerName)")

        // Handle custom provider
        if providerName == "custom" {
            logger.debug("AppState.getProvider: Custom provider selected")
            let apiKey = KeychainManager.shared.retrieveCustomProviderApiKey(for: command.id)
            if let baseURL = command.customProviderBaseURL,
               let apiKey,
               let model = command.customProviderModel {
                logger.debug("AppState.getProvider: Creating CustomProvider with baseURL=\(baseURL), model=\(model)")
                let config = CustomProviderConfig(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    model: model
                )
                return CustomProvider(config: config)
            } else {
                logger.warning("AppState.getProvider: Custom provider config incomplete - baseURL=\(command.customProviderBaseURL ?? "nil"), apiKey=\(apiKey != nil ? "set" : "nil"), model=\(command.customProviderModel ?? "nil")")
            }
            // Fallback to active provider if custom config is incomplete
            return activeProvider
        }

        // If there's a model override, create a temporary provider instance with that model
        if let modelOverride = command.modelOverride {
            return createProviderWithModel(providerName: providerName, model: modelOverride)
        }

        // Otherwise use the default provider instance
        switch providerName {
        case "openai":
            return openAIProvider
        case "gemini":
            return geminiProvider
        case "anthropic":
            return anthropicProvider
        case "ollama":
            return ollamaProvider
        case "mistral":
            return mistralProvider
        case "openrouter":
            return openRouterProvider
        case "local":
            return localLLMProvider
        default:
            return activeProvider
        }
    }

    /// Create or retrieve a cached provider instance with a specific model override
    private func createProviderWithModel(providerName: String, model: String) -> any AIProvider {
        let cacheKey = "\(providerName):\(model)"

        // Return cached provider if available
        if let cached = modelOverrideProviderCache[cacheKey] {
            return cached
        }

        let asettings = AppSettings.shared
        let provider: any AIProvider

        switch providerName {
        case "openai":
            let config = OpenAIConfig(
                apiKey: asettings.openAIApiKey,
                baseURL: asettings.openAIBaseURL,
                model: model
            )
            provider = OpenAIProvider(config: config)

        case "gemini":
            let config = GeminiConfig(
                apiKey: asettings.geminiApiKey,
                modelName: model
            )
            provider = GeminiProvider(config: config)

        case "anthropic":
            let config = AnthropicConfig(
                apiKey: asettings.anthropicApiKey,
                model: model
            )
            provider = AnthropicProvider(config: config)

        case "ollama":
            let config = OllamaConfig(
                baseURL: asettings.ollamaBaseURL,
                model: model,
                keepAlive: asettings.ollamaKeepAlive
            )
            provider = OllamaProvider(config: config)

        case "mistral":
            let config = MistralConfig(
                apiKey: asettings.mistralApiKey,
                baseURL: asettings.mistralBaseURL,
                model: model
            )
            provider = MistralProvider(config: config)

        case "openrouter":
            let config = OpenRouterConfig(
                apiKey: asettings.openRouterApiKey,
                model: model
            )
            provider = OpenRouterProvider(config: config)

        case "local":
            return localLLMProvider

        default:
            return activeProvider
        }

        // Evict oldest entries if cache is full (simple FIFO)
        if modelOverrideProviderCache.count >= maxCacheSize {
            if let firstKey = modelOverrideProviderCache.keys.first {
                modelOverrideProviderCache.removeValue(forKey: firstKey)
            }
        }

        // Cache the new provider
        modelOverrideProviderCache[cacheKey] = provider
        return provider
    }

    /// Clear the model override provider cache (call when settings change)
    func clearProviderCache() {
        modelOverrideProviderCache.removeAll()
    }

    private init() {
        // Read from AppSettings
        let asettings = AppSettings.shared
        self.currentProvider = asettings.currentProvider

        // Initialize Gemini with custom model support
        let geminiModelEnum = asettings.geminiModel
        let geminiModelName = (geminiModelEnum == .custom)
        ? asettings.geminiCustomModel
        : geminiModelEnum.rawValue
        let geminiConfig = GeminiConfig(
            apiKey: asettings.geminiApiKey,
            modelName: geminiModelName
        )
        self.geminiProvider = GeminiProvider(config: geminiConfig)

        // Initialize OpenAI
        let openAIConfig = OpenAIConfig(
            apiKey: asettings.openAIApiKey,
            baseURL: asettings.openAIBaseURL,
            model: asettings.openAIModel
        )
        self.openAIProvider = OpenAIProvider(config: openAIConfig)

        // Initialize Mistral
        let mistralConfig = MistralConfig(
            apiKey: asettings.mistralApiKey,
            baseURL: asettings.mistralBaseURL,
            model: asettings.mistralModel
        )
        self.mistralProvider = MistralProvider(config: mistralConfig)

        self.localLLMProvider = LocalModelProvider()

        // Initialize Anthropic
        let anthropicConfig = AnthropicConfig(
            apiKey: asettings.anthropicApiKey,
            model: asettings.anthropicModel
        )
        self.anthropicProvider = AnthropicProvider(config: anthropicConfig)

        // Initialize OllamaProvider with its settings.
        let ollamaConfig = OllamaConfig(
            baseURL: asettings.ollamaBaseURL,
            model: asettings.ollamaModel,
            keepAlive: asettings.ollamaKeepAlive
        )
        self.ollamaProvider = OllamaProvider(config: ollamaConfig)

        // Initialize OpenRouter
        let openRouterModelEnum = OpenRouterModel(rawValue: asettings.openRouterModel) ?? .gpt4o
        let openRouterModelName = (openRouterModelEnum == .custom)
            ? asettings.openRouterCustomModel
            : openRouterModelEnum.rawValue
        let openRouterConfig = OpenRouterConfig(
            apiKey: asettings.openRouterApiKey,
            model: openRouterModelName
        )
        self.openRouterProvider = OpenRouterProvider(config: openRouterConfig)

        if asettings.openAIApiKey.isEmpty &&
            asettings.geminiApiKey.isEmpty &&
            asettings.mistralApiKey.isEmpty &&
            asettings.openRouterApiKey.isEmpty &&
            asettings.anthropicApiKey.isEmpty {
            logger.warning("No API keys configured.")
        }

        // Perform migration from old system to new CommandManager if needed
        MigrationHelper.shared.migrateIfNeeded(
            commandManager: commandManager,
            customCommandsManager: customCommandsManager
        )
    }

    // For Gemini changes
    func saveGeminiConfig(apiKey: String, model: GeminiModel, customModelName: String? = nil) {
        AppSettings.shared.geminiApiKey = apiKey
        AppSettings.shared.geminiModel = model
        if model == .custom, let custom = customModelName {
            AppSettings.shared.geminiCustomModel = custom
        }

        let modelName = (model == .custom) ? (customModelName ?? "") : model.rawValue
        let config = GeminiConfig(apiKey: apiKey, modelName: modelName)
        geminiProvider = GeminiProvider(config: config)
        clearProviderCache()
    }

    // For OpenAI changes
    func saveOpenAIConfig(apiKey: String, baseURL: String, organization: String?, project: String?, model: String) {
        let asettings = AppSettings.shared
        asettings.openAIApiKey = apiKey
        asettings.openAIBaseURL = baseURL
        asettings.openAIOrganization = organization
        asettings.openAIProject = project
        asettings.openAIModel = model

        let config = OpenAIConfig(apiKey: apiKey, baseURL: baseURL, model: model)
        openAIProvider = OpenAIProvider(config: config)
        clearProviderCache()
    }

    // Update provider and persist to settings
    func setCurrentProvider(_ provider: String) {
        currentProvider = provider
        AppSettings.shared.currentProvider = provider
    }

    func saveMistralConfig(apiKey: String, baseURL: String, model: String) {
        let asettings = AppSettings.shared
        asettings.mistralApiKey = apiKey
        asettings.mistralBaseURL = baseURL
        asettings.mistralModel = model

        let config = MistralConfig(
            apiKey: apiKey,
            baseURL: baseURL,
            model: model
        )
        mistralProvider = MistralProvider(config: config)
        clearProviderCache()
    }

    // For Anthropic changes
    func saveAnthropicConfig(apiKey: String, model: String) {
        let asettings = AppSettings.shared
        asettings.anthropicApiKey = apiKey
        asettings.anthropicModel = model

        let config = AnthropicConfig(apiKey: apiKey, model: model)
        anthropicProvider = AnthropicProvider(config: config)
        clearProviderCache()
        logger.debug("Anthropic config saved and provider updated.")
    }

    // For updating Ollama settings
    func saveOllamaConfig(baseURL: String, model: String, keepAlive: String) {
        let asettings = AppSettings.shared
        asettings.ollamaBaseURL = baseURL
        asettings.ollamaModel = model
        asettings.ollamaKeepAlive = keepAlive

        let config = OllamaConfig(baseURL: baseURL, model: model, keepAlive: keepAlive)
        ollamaProvider = OllamaProvider(config: config)
        clearProviderCache()
    }

    // For updating OpenRouter settings
    func saveOpenRouterConfig(apiKey: String, model: OpenRouterModel, customModelName: String? = nil) {
        AppSettings.shared.openRouterApiKey = apiKey
        AppSettings.shared.openRouterModel = model.rawValue
        if model == .custom, let custom = customModelName {
            AppSettings.shared.openRouterCustomModel = custom
        }
        let modelName = (model == .custom) ? (customModelName ?? "") : model.rawValue
        let config = OpenRouterConfig(apiKey: apiKey, model: modelName)
        openRouterProvider = OpenRouterProvider(config: config)
        clearProviderCache()
    }

    /// Saves provider settings based on the currently selected provider
    /// This is a unified method to reduce code duplication between OnboardingView and SettingsView
    func saveCurrentProviderSettings() {
        let settings = AppSettings.shared

        switch settings.currentProvider {
        case "gemini":
            saveGeminiConfig(
                apiKey: settings.geminiApiKey,
                model: settings.geminiModel,
                customModelName: settings.geminiCustomModel
            )
        case "mistral":
            saveMistralConfig(
                apiKey: settings.mistralApiKey,
                baseURL: settings.mistralBaseURL,
                model: settings.mistralModel
            )
        case "openai":
            saveOpenAIConfig(
                apiKey: settings.openAIApiKey,
                baseURL: settings.openAIBaseURL,
                organization: settings.openAIOrganization,
                project: settings.openAIProject,
                model: settings.openAIModel
            )
        case "anthropic":
            saveAnthropicConfig(
                apiKey: settings.anthropicApiKey,
                model: settings.anthropicModel
            )
        case "openrouter":
            saveOpenRouterConfig(
                apiKey: settings.openRouterApiKey,
                model: OpenRouterModel(rawValue: settings.openRouterModel) ?? .gpt4o,
                customModelName: settings.openRouterCustomModel
            )
        case "ollama":
            saveOllamaConfig(
                baseURL: settings.ollamaBaseURL,
                model: settings.ollamaModel,
                keepAlive: settings.ollamaKeepAlive
            )
            UserDefaults.standard.set(settings.ollamaImageMode.rawValue, forKey: "ollama_image_mode")
        default:
            break
        }

        setCurrentProvider(settings.currentProvider)
    }

    // Process a command (unified method for all command types)
    func processCommand(_ command: CommandModel) {
        guard !selectedText.isEmpty, !isProcessing else { return }

        isProcessing = true

        Task {
            do {
                let prompt = command.prompt

                // Get the appropriate provider for this command (respects per-command overrides)
                let provider = getProvider(for: command)

                var result = try await provider.processText(
                    systemPrompt: prompt,
                    userPrompt: selectedText,
                    images: [],
                    streaming: false
                )

                // Preserve trailing newlines from the original selection
                // This is important for triple-click selections which include the trailing newline
                if selectedText.hasSuffix("\n") && !result.hasSuffix("\n") {
                    result += "\n"
                    logger.debug("Added trailing newline to match input")
                }

                if command.useResponseWindow {
                    let window = ResponseWindow(
                        title: "\(command.name) Result",
                        content: result,
                        selectedText: selectedText,
                        option: nil,
                        provider: provider
                    )

                    WindowManager.shared.addResponseWindow(window)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                } else {
                    if command.preserveFormatting, selectedAttributedText != nil {
                        replaceSelectedTextPreservingAttributes(with: result)
                    } else {
                        replaceSelectedText(with: result)
                    }
                }
            } catch {
                logger.error("Error processing command: \(error.localizedDescription)")
            }

            isProcessing = false
        }
    }

    // MARK: - Fixed: Proper Window Activation Verification

    func replaceSelectedText(with newText: String) {
        // Take a snapshot of the current clipboard BEFORE we overwrite it
        let clipboardSnapshot = NSPasteboard.general.createSnapshot()

        // Set the new text on the clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: [])
        pasteboard.writeObjects([newText as NSString])

        // Reactivate previous application
        if let previousApp = previousApplication {
            let didActivate = previousApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            if !didActivate {
                logger.warning("Failed to activate previous app: \(previousApp.bundleIdentifier ?? "unknown")")
            }

            // Wait for window activation, paste, then restore clipboard
            activateWindowAndPaste(for: previousApp, clipboardSnapshot: clipboardSnapshot)
        }
    }

    private func activateWindowAndPaste(for app: NSRunningApplication, clipboardSnapshot: ClipboardSnapshot) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let maxAttempts = 100 // ~1 second with 10ms intervals
            let startTime = Date()
            var attempts = 0

            while true {
                if Task.isCancelled {
                    logger.debug("Paste operation cancelled before activation")
                    return
                }

                let isFrontmost =
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleIdentifier
                if isFrontmost || attempts >= maxAttempts || Date().timeIntervalSince(startTime) >= 2.0 {
                    // Perform the paste
                    self.simulatePaste()

                    // Wait a moment for the paste to complete, then restore the clipboard
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        logger.debug("Paste delay interrupted: \(error.localizedDescription)")
                    }

                    // Restore the original clipboard content
                    let restored = NSPasteboard.general.restore(snapshot: clipboardSnapshot)
                    if restored {
                        logger.debug("Clipboard restored after paste")
                    } else {
                        logger.error("Clipboard restore failed after paste")
                        self.showClipboardRestoreFailedAlert(targetApp: app)
                    }
                    break
                }

                attempts += 1
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    logger.debug("Paste activation wait interrupted: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    func replaceSelectedTextPreservingAttributes(with corrected: String) {
        guard let original = selectedAttributedText else {
            replaceSelectedText(with: corrected)
            return
        }

        // Take a snapshot of the current clipboard BEFORE we overwrite it
        let clipboardSnapshot = NSPasteboard.general.createSnapshot()

        let mutable = NSMutableAttributedString(attributedString: original)
        mutable.applyCharacterDiff(from: original.string, to: corrected)

        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: [])

        // Prefer HTML for web editors (e.g., Gmail in browsers), then RTF, always include plain text
        let fullRange = NSRange(location: 0, length: mutable.length)
        let htmlData = try? mutable.data(
            from: fullRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
            ]
        )
        let rtfData = try? mutable.data(
            from: fullRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf,
            ]
        )

        let item = NSPasteboardItem()

        if let htmlData {
            let htmlType = NSPasteboard.PasteboardType(UTType.html.identifier)
            item.setData(htmlData, forType: htmlType)
        }
        if let rtfData {
            let rtfType = NSPasteboard.PasteboardType(UTType.rtf.identifier)
            item.setData(rtfData, forType: rtfType)
        }
        item.setString(corrected, forType: .string)

        pb.writeObjects([item])

        if let previous = previousApplication {
            let didActivate = previous.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            if !didActivate {
                logger.warning("Failed to activate previous app: \(previous.bundleIdentifier ?? "unknown")")
            }
            activateWindowAndPaste(for: previous, clipboardSnapshot: clipboardSnapshot)
        }
    }

    // MARK: - Fixed: Use cgSessionEventTap for Reliable Event Ordering

    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("Failed to create CGEventSource")
            return
        }

        // Create Command + V key down event
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
            logger.error("Failed to create key down event")
            return
        }
        keyDown.flags = .maskCommand

        // Create Command + V key up event
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logger.error("Failed to create key up event")
            return
        }
        keyUp.flags = .maskCommand

        // Post to cgSessionEventTap for more predictable ordering
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private func showClipboardRestoreFailedAlert(targetApp: NSRunningApplication) {
        let alert = NSAlert()
        alert.messageText = "Clipboard Restore Failed"
        let bundleId = targetApp.bundleIdentifier ?? "unknown app"
        alert.informativeText =
            "Writing Tools couldn't restore your clipboard after pasting into \(bundleId). You may need to re-copy your previous clipboard contents."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension NSMutableAttributedString {
    /// Transforms *self* so that `self.string == new`, preserving
    /// per-character attributes wherever possible.
    func applyCharacterDiff(from old: String, to new: String) {
        // Build the diff
        let diff = Array(new).difference(from: Array(old))

        // Collect removals & insertions with their offsets
        var removals: [Int] = []
        var insertions: [(offset: Int, char: Character)] = []

        for change in diff {
            switch change {
            case let .remove(offset, _, _):
                removals.append(offset)
            case let .insert(offset, element, _):
                insertions.append((offset, element))
            }
        }

        // Apply removals back-to-front
        for index in removals.sorted(by: >) {
            deleteCharacters(in: NSRange(location: index, length: 1))
        }

        // Apply insertions front-to-back
        for (index, ch) in insertions.sorted(by: { $0.offset < $1.offset }) {
            let inherited: [NSAttributedString.Key: Any]
            if index > 0 && index - 1 < self.length {
                inherited = attributes(at: index - 1, effectiveRange: nil)
            } else {
                inherited = [:]
            }
            let piece = NSAttributedString(string: String(ch), attributes: inherited)
            insert(piece, at: index)
        }
    }
}

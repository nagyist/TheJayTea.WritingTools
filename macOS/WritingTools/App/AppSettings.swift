import Foundation
import Observation

extension Notification.Name {
    static let iCloudCommandSyncPreferenceDidChange = Notification.Name("iCloudCommandSyncPreferenceDidChange")
}

// A singleton for app-wide settings that wraps UserDefaults access
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let keychain = KeychainManager.shared
    @ObservationIgnored private var keychainWriteTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var keychainWriteGenerations: [String: UInt64] = [:]
    @ObservationIgnored private let keychainWriteDelay: Duration = .milliseconds(350)
    
    // MARK: - Published Settings
    var themeStyle: String {
        didSet {
            defaults.set(themeStyle, forKey: "theme_style")
            useGradientTheme = (themeStyle != "standard")
        }
    }
    
    // API Keys now use computed properties backed by Keychain
    var geminiApiKey: String = "" {
        didSet {
            scheduleKeychainWrite(geminiApiKey, forKey: "gemini_api_key")
        }
    }
    
    var geminiModel: GeminiModel {
        didSet { defaults.set(geminiModel.rawValue, forKey: "gemini_model") }
    }
    
    var geminiCustomModel: String {
        didSet { defaults.set(geminiCustomModel, forKey: "gemini_custom_model") }
    }
    
    var openAIApiKey: String = "" {
        didSet {
            scheduleKeychainWrite(openAIApiKey, forKey: "openai_api_key")
        }
    }
    
    var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: "openai_base_url") }
    }
    
    var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: "openai_model") }
    }
    
    var openAIOrganization: String? {
        didSet { defaults.set(openAIOrganization, forKey: "openai_organization") }
    }
    
    var openAIProject: String? {
        didSet { defaults.set(openAIProject, forKey: "openai_project") }
    }
    
    var currentProvider: String {
        didSet { defaults.set(currentProvider, forKey: "current_provider") }
    }
    
    var shortcutText: String {
        didSet { defaults.set(shortcutText, forKey: "shortcut") }
    }
    
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "has_completed_onboarding") }
    }
    
    var useGradientTheme: Bool {
        didSet { defaults.set(useGradientTheme, forKey: "use_gradient_theme") }
    }
    
    // MARK: - HotKey data
    var hotKeyCode: Int {
        didSet { defaults.set(hotKeyCode, forKey: "hotKey_keyCode") }
    }
    var hotKeyModifiers: Int {
        didSet { defaults.set(hotKeyModifiers, forKey: "hotKey_modifiers") }
    }
    var hotkeysPaused: Bool {
        didSet { defaults.set(hotkeysPaused, forKey: "hotkeys_paused") }
    }
    
    var mistralApiKey: String = "" {
        didSet {
            scheduleKeychainWrite(mistralApiKey, forKey: "mistral_api_key")
        }
    }
    
    var mistralBaseURL: String {
        didSet { defaults.set(mistralBaseURL, forKey: "mistral_base_url") }
    }
    
    var mistralModel: String {
        didSet { defaults.set(mistralModel, forKey: "mistral_model") }
    }
    
    // Ollama settings:
    var ollamaBaseURL: String {
        didSet { defaults.set(ollamaBaseURL, forKey: "ollama_base_url") }
    }
    
    var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollama_model") }
    }
    
    var ollamaKeepAlive: String {
        didSet { defaults.set(ollamaKeepAlive, forKey: "ollama_keep_alive") }
    }
    
    var ollamaImageMode: OllamaImageMode {
        didSet { defaults.set(ollamaImageMode.rawValue, forKey: "ollama_image_mode") }
    }
    
    var anthropicApiKey: String = "" {
        didSet {
            scheduleKeychainWrite(anthropicApiKey, forKey: "anthropic_api_key")
        }
    }
    
    var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: "anthropic_model") }
    }
    
    var openRouterApiKey: String = "" {
        didSet {
            scheduleKeychainWrite(openRouterApiKey, forKey: "openrouter_api_key")
        }
    }
    var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: "openrouter_model") }
    }
    var openRouterCustomModel: String {
        didSet { defaults.set(openRouterCustomModel, forKey: "openrouter_custom_model") }
    }
    
    // Store the ID (rawValue) of the selected local LLM model type
    var selectedLocalLLMId: String? {
        didSet { defaults.set(selectedLocalLLMId, forKey: "selected_local_llm_id") }
    }
    
    // MARK: - Custom Commands Settings
    var openCustomCommandsInResponseWindow: Bool {
        didSet { defaults.set(openCustomCommandsInResponseWindow, forKey: "open_custom_commands_in_response_window") }
    }

    var enableICloudCommandSync: Bool {
        didSet {
            defaults.set(enableICloudCommandSync, forKey: "enable_icloud_command_sync")
            NotificationCenter.default.post(name: .iCloudCommandSyncPreferenceDidChange, object: nil)
        }
    }
    
    // MARK: - Init
    private init() {
        let defaults = UserDefaults.standard
        
        // MARK: - Perform Keychain Migration (One-time on first launch after update)
        KeychainMigrationManager.shared.migrateIfNeeded()
        
        // Initialize the theme style first
        self.themeStyle = defaults.string(forKey: "theme_style") ?? "gradient"
        
        // Load API Keys from Keychain (post-migration)
        self.geminiApiKey = (try? keychain.retrieve(forKey: "gemini_api_key")) ?? ""
        let geminiModelStr = defaults.string(forKey: "gemini_model") ?? GeminiModel.gemmabig.rawValue
        self.geminiModel = GeminiModel(rawValue: geminiModelStr) ?? .gemmabig
        
        self.geminiCustomModel = defaults.string(forKey: "gemini_custom_model") ?? ""
        
        self.openAIApiKey = (try? keychain.retrieve(forKey: "openai_api_key")) ?? ""
        self.openAIBaseURL = defaults.string(forKey: "openai_base_url") ?? OpenAIConfig.defaultBaseURL
        self.openAIModel = defaults.string(forKey: "openai_model") ?? OpenAIConfig.defaultModel
        self.openAIOrganization = defaults.string(forKey: "openai_organization")
        self.openAIProject = defaults.string(forKey: "openai_project")
        
        self.mistralApiKey = (try? keychain.retrieve(forKey: "mistral_api_key")) ?? ""
        self.mistralBaseURL = defaults.string(forKey: "mistral_base_url") ?? MistralConfig.defaultBaseURL
        self.mistralModel = defaults.string(forKey: "mistral_model") ?? MistralConfig.defaultModel
        
        self.ollamaBaseURL = defaults.string(forKey: "ollama_base_url") ?? OllamaConfig.defaultBaseURL
        self.ollamaModel = defaults.string(forKey: "ollama_model") ?? OllamaConfig.defaultModel
        self.ollamaKeepAlive = defaults.string(forKey: "ollama_keep_alive") ?? OllamaConfig.defaultKeepAlive
        
        self.currentProvider = defaults.string(forKey: "current_provider") ?? "gemini"
        self.shortcutText = defaults.string(forKey: "shortcut") ?? "⌥ Space"
        self.hasCompletedOnboarding = defaults.bool(forKey: "has_completed_onboarding")
        self.useGradientTheme = defaults.bool(forKey: "use_gradient_theme")
        
        // HotKey
        self.hotKeyCode = defaults.integer(forKey: "hotKey_keyCode")
        self.hotKeyModifiers = defaults.integer(forKey: "hotKey_modifiers")
        self.hotkeysPaused = defaults.bool(forKey: "hotkeys_paused")
        
        let ollamaImageModeRaw = defaults.string(forKey: "ollama_image_mode") ?? OllamaImageMode.ocr.rawValue
        self.ollamaImageMode = OllamaImageMode(rawValue: ollamaImageModeRaw) ?? .ocr
        
        self.anthropicApiKey = (try? keychain.retrieve(forKey: "anthropic_api_key")) ?? ""
        self.anthropicModel = defaults.string(forKey: "anthropic_model") ?? AnthropicConfig.defaultModel
        
        self.selectedLocalLLMId = defaults.string(forKey: "selected_local_llm_id")
        
        self.openRouterApiKey = (try? keychain.retrieve(forKey: "openrouter_api_key")) ?? ""
        self.openRouterModel = defaults.string(forKey: "openrouter_model") ?? OpenRouterConfig.defaultModel
        self.openRouterCustomModel = defaults.string(forKey: "openrouter_custom_model") ?? ""
        
        // Custom commands setting - default to true (open in response window)
        self.openCustomCommandsInResponseWindow = defaults.object(forKey: "open_custom_commands_in_response_window") as? Bool ?? true

        // Cloud command sync setting defaults to false until explicitly enabled.
        self.enableICloudCommandSync = defaults.object(forKey: "enable_icloud_command_sync") as? Bool ?? false
    }

    deinit {
        keychainWriteTasks.values.forEach { $0.cancel() }
        keychainWriteTasks.removeAll()
        keychainWriteGenerations.removeAll()
    }

    private func scheduleKeychainWrite(_ value: String, forKey key: String) {
        let generation = (keychainWriteGenerations[key] ?? 0) + 1
        keychainWriteGenerations[key] = generation
        keychainWriteTasks[key]?.cancel()

        keychainWriteTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.clearKeychainWriteTaskReference(forKey: key, generation: generation) }
            try? await Task.sleep(for: self.keychainWriteDelay)
            guard !Task.isCancelled else { return }
            let keychainRef = self.keychain
            let valueToSave = value
            let keyToSave = key
            Task.detached(priority: .utility) {
                try? keychainRef.save(valueToSave, forKey: keyToSave)
            }
        }
    }

    private func clearKeychainWriteTaskReference(forKey key: String, generation: UInt64) {
        guard keychainWriteGenerations[key] == generation else { return }
        keychainWriteTasks[key] = nil
        keychainWriteGenerations[key] = nil
    }
    
    // MARK: - Convenience
    func resetAll() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)

        // Clear Keychain API keys
        try? keychain.clearAllApiKeys()
    }
}

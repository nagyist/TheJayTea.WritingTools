import Foundation
import Observation

extension Notification.Name {
    static let iCloudCommandSyncPreferenceDidChange = Notification.Name("iCloudCommandSyncPreferenceDidChange")
    static let apiKeyDidChange = Notification.Name("apiKeyDidChange")
}

// A singleton for app-wide settings that wraps UserDefaults access
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let keychain = KeychainManager.shared
    @ObservationIgnored private var isBootstrapping = true
    
    
    // MARK: - Published Settings
    var themeStyle: String {
        didSet {
            defaults.set(themeStyle, forKey: "theme_style")
        }
    }
    
    // API Keys now use computed properties backed by Keychain
    var geminiApiKey: String = "" {
        didSet {
            guard !isBootstrapping, oldValue != geminiApiKey else { return }
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
            guard !isBootstrapping, oldValue != openAIApiKey else { return }
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
        themeStyle != "standard"
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
            guard !isBootstrapping, oldValue != mistralApiKey else { return }
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
            guard !isBootstrapping, oldValue != anthropicApiKey else { return }
            scheduleKeychainWrite(anthropicApiKey, forKey: "anthropic_api_key")
        }
    }
    
    var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: "anthropic_model") }
    }
    
    var openRouterApiKey: String = "" {
        didSet {
            guard !isBootstrapping, oldValue != openRouterApiKey else { return }
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
        let legacyGradientThemeKey = "use_gradient_theme"
        
        // MARK: - Perform Keychain Migration (One-time on first launch after update)
        KeychainMigrationManager.shared.migrateIfNeeded()
        
        // Migrate legacy boolean theme key to theme_style once, then remove legacy key.
        if defaults.string(forKey: "theme_style") == nil,
           defaults.object(forKey: legacyGradientThemeKey) != nil {
            let migratedThemeStyle = defaults.bool(forKey: legacyGradientThemeKey) ? "gradient" : "standard"
            defaults.set(migratedThemeStyle, forKey: "theme_style")
            defaults.removeObject(forKey: legacyGradientThemeKey)
        }

        // Initialize the theme style first.
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

        isBootstrapping = false
    }

    /// Writes an API key to the Keychain immediately.
    /// API keys change rarely (only when edited in Settings), so there is no
    /// need for debouncing. Writing immediately avoids data loss if the app
    /// crashes or is force-quit before a debounced write completes.
    private func scheduleKeychainWrite(_ value: String, forKey key: String) {
        // Notify observers that an API key changed so caches can be invalidated
        NotificationCenter.default.post(name: .apiKeyDidChange, object: nil)

        try? keychain.save(value, forKey: key)
    }

    // MARK: - Convenience
    func resetAll() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)

        // Clear Keychain API keys
        try? keychain.clearAllApiKeys()
    }
}

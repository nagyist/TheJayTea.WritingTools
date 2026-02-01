import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

private let logger = AppLogger.logger("AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // Static status item to prevent deallocation
    private static var sharedStatusItem: NSStatusItem?

    // Property to track service-triggered popups
    private var isServiceTriggered: Bool = false

    // Computed property to manage the menu bar status item
    var statusBarItem: NSStatusItem! {
        get {
            if AppDelegate.sharedStatusItem == nil {
                AppDelegate.sharedStatusItem =
                    NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                configureStatusBarItem()
            }
            return AppDelegate.sharedStatusItem
        }
        set {
            AppDelegate.sharedStatusItem = newValue
        }
    }

    let appState = AppState.shared
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var settingsHostingView: NSHostingView<SettingsView>?
    private var aboutHostingView: NSHostingView<AboutView>?

    // Pasteboard monitoring
    private var pasteboardObserver: NSObjectProtocol?
    @objc private func toggleHotkeys() {
        AppSettings.shared.hotkeysPaused.toggle()
        setupMenuBar()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self

        if CommandLine.arguments.contains("--reset") {
            Task { @MainActor [weak self] in
                self?.performRecoveryReset()
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.setupMenuBar()
            if !AppSettings.shared.hasCompletedOnboarding {
                self?.showOnboarding()
            }
        }

        // Register the main popup shortcut
        KeyboardShortcuts.onKeyUp(for: .showPopup) { [weak self] in
            if !AppSettings.shared.hotkeysPaused {
                self?.showPopup()
            } else {
                logger.info("Hotkeys are paused")
            }
        }

        // Set up command-specific shortcuts
        setupCommandShortcuts()

        // Register for command changes to update shortcuts
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(setupCommandShortcuts),
            name: NSNotification.Name("CommandsChanged"),
            object: nil
        )
    }

    @objc private func setupCommandShortcuts() {
        for command in appState.commandManager.commands.filter({ !$0.hasShortcut }) {
            KeyboardShortcuts.reset(.commandShortcut(for: command.id))
        }

        for command in appState.commandManager.commands.filter({ $0.hasShortcut }) {
            KeyboardShortcuts.onKeyUp(for: .commandShortcut(for: command.id)) {
                [weak self] in
                guard let self = self, !AppSettings.shared.hotkeysPaused else {
                    return
                }
                self.executeCommandDirectly(command)
            }
        }
    }

    private func executeCommandDirectly(_ command: CommandModel) {
        guard !appState.isProcessing else {
            logger.debug("Command ignored because a request is already in progress.")
            return
        }
        appState.activeProvider.cancel()

        Task { @MainActor in
            // Store the previous app BEFORE any operations
            let previousApp = NSWorkspace.shared.frontmostApplication

            guard let capture = await ClipboardCoordinator.shared.captureSelection() else {
                logger.debug("Clipboard capture skipped because another operation is in progress")
                return
            }

            guard capture.didChange else {
                logger.warning("No new content was copied for command: \(command.name)")
                return
            }

            guard !capture.text.isEmpty else {
                logger.info("No text selected for command: \(command.name) - pasteboard contained no text")
                return
            }

            logger.debug("Successfully captured text for command \(command.name) (length: \(capture.text.count) characters)")

            // Store data in appState
            self.appState.selectedImages = capture.images
            self.appState.selectedAttributedText = capture.attributedText
            self.appState.selectedText = capture.text

            // Set previous app AFTER we've successfully copied
            if let previousApp = previousApp {
                self.appState.previousApplication = previousApp
            }

            // Process the command with the captured data
            await self.processCommandWithUI(command)
        }
    }

    private func processCommandWithUI(_ command: CommandModel) async {
        if appState.isProcessing {
            return
        }

        appState.isProcessing = true

        defer {
            appState.isProcessing = false
        }

        do {
            // Get the appropriate provider for this command (respects per-command overrides)
            let provider = appState.getProvider(for: command)

            var result = try await provider.processText(
                systemPrompt: command.prompt,
                userPrompt: appState.selectedText,
                images: appState.selectedImages,
                streaming: false
            )

            // Preserve trailing newlines from the original selection
            // This is important for triple-click selections which include the trailing newline
            let originalText = appState.selectedText
            if originalText.hasSuffix("\n") && !result.hasSuffix("\n") {
                result += "\n"
                logger.debug("Added trailing newline to match input")
            }

            await MainActor.run {
                if command.useResponseWindow {
                    let window = ResponseWindow(
                        title: command.name,
                        content: result,
                        selectedText: appState.selectedText,
                        option: nil,
                        provider: provider
                    )

                    NSApp.activate(ignoringOtherApps: true)
                    WindowManager.shared.addResponseWindow(window)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                } else {
                    if command.preserveFormatting, appState.selectedAttributedText != nil {
                        appState.replaceSelectedTextPreservingAttributes(with: result)
                    } else {
                        appState.replaceSelectedText(with: result)
                    }
                }
            }
        } catch {
            logger.error("Error processing command \(command.name): \(error.localizedDescription)")

            // Show error alert
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Command Error"
                alert.informativeText = "Failed to process '\(command.name)': \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name("CommandsChanged"),
            object: nil
        )
        if let observer = pasteboardObserver {
            NotificationCenter.default.removeObserver(observer)
            pasteboardObserver = nil
        }
        WindowManager.shared.cleanupWindows()
    }

    private func recreateStatusBarItem() {
        AppDelegate.sharedStatusItem = nil
        _ = self.statusBarItem
    }

    private func configureStatusBarItem() {
        guard let button = statusBarItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: "pencil.circle",
            accessibilityDescription: "Writing Tools"
        )
    }

    private func setupMenuBar() {
        guard let statusBarItem = self.statusBarItem else {
            logger.error("Failed to create status bar item")
            return
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(aboutItem)

        let hotkeyTitle = AppSettings.shared.hotkeysPaused ? "Resume Hotkeys" : "Pause Hotkeys"
        let hotkeyItem = NSMenuItem(title: hotkeyTitle, action: #selector(toggleHotkeys), keyEquivalent: "")
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(title: "Reset App", action: #selector(confirmResetApp), keyEquivalent: "")
        menu.addItem(resetItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        statusBarItem.menu = menu
    }

    @objc private func confirmResetApp() {
        let alert = NSAlert()
        alert.messageText = "Reset Writing Tools?"
        alert.informativeText = "This will reset windows and UI state. Your commands and settings will remain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            resetApp()
        }
    }

    @objc private func resetApp() {
        WindowManager.shared.cleanupWindows()

        recreateStatusBarItem()
        setupMenuBar()

        let alert = NSAlert()
        alert.messageText = "App Reset Complete"
        alert.informativeText =
            "The app has been reset. If you're still experiencing issues, try restarting the app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func performRecoveryReset() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)

        WindowManager.shared.cleanupWindows()

        recreateStatusBarItem()
        setupMenuBar()

        let alert = NSAlert()
        alert.messageText = "Recovery Complete"
        alert.informativeText =
            "The app has been reset to its default state."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showSettings() {
        settingsWindow?.close()
        closePopupWindow()
        settingsWindow = nil
        settingsHostingView = nil

        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.isReleasedWhenClosed = false
        settingsWindow?.minSize = NSSize(width: 520, height: 440)

        let settingsView =
            SettingsView(appState: appState, showOnlyApiSetup: false)
        settingsHostingView = NSHostingView(rootView: settingsView)
        settingsWindow?.contentView = settingsHostingView
        if let window = settingsWindow, let hostingView = settingsHostingView {
            WindowManager.shared.registerSettingsWindow(window, hostingView: hostingView)
        }

        if let window = settingsWindow {
            window.title = "Settings"
            window.level = .floating
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    @objc private func showAbout() {
        aboutWindow?.close()
        aboutWindow = nil
        aboutHostingView = nil

        aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow?.isReleasedWhenClosed = false

        let aboutView = AboutView()
        aboutHostingView = NSHostingView(rootView: aboutView)
        aboutWindow?.contentView = aboutHostingView
        aboutWindow?.delegate = self

        if let window = aboutWindow {
            window.title = "About Writing Tools"
            window.level = .floating
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func showOnboarding() {
        WindowManager.shared.showOnboarding(appState: appState)
    }

    @MainActor
    private func showPopup() {
        appState.activeProvider.cancel()

        Task { @MainActor in
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                self.appState.previousApplication = frontApp
            }

            self.closePopupWindow()

            guard let capture = await ClipboardCoordinator.shared.captureSelection() else {
                logger.debug("Clipboard capture skipped because another operation is in progress")
                return
            }

            if !capture.didChange {
                logger.warning("Pasteboard did not change after copy; clearing selection to avoid stale context")
            }

            self.appState.selectedAttributedText = capture.attributedText
            self.appState.selectedText = capture.text
            self.appState.selectedImages = capture.images

            let window = PopupWindow(appState: self.appState)
            if !capture.text.isEmpty || !capture.images.isEmpty {
                window.setContentSize(NSSize(width: 400, height: 400))
            } else {
                window.setContentSize(NSSize(width: 400, height: 100))
            }

            window.positionNearMouse()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func closePopupWindow() {
        WindowManager.shared.dismissPopup()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isServiceTriggered else { return }

        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self] in
            if window == self?.settingsWindow {
                self?.settingsHostingView = nil
                self?.settingsWindow = nil
            } else if window == self?.aboutWindow {
                self?.aboutHostingView = nil
                self?.aboutWindow = nil
            }
        }
    }
}

extension AppDelegate {
    override func awakeFromNib() {
        super.awakeFromNib()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }
}

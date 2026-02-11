import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

private let logger = AppLogger.logger("AppDelegate")

/// AppDelegate handles keyboard shortcuts, services, and popup window management.
/// Menu bar UI is handled by SwiftUI's MenuBarExtra in writing_toolsApp.swift.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var iCloudSyncObserver: NSObjectProtocol?
    
    let appState = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self

        if CommandLine.arguments.contains("--reset") {
            Task { @MainActor [weak self] in
                self?.performRecoveryReset()
            }
            return
        }

        Task { @MainActor in
            if !AppSettings.shared.hasCompletedOnboarding {
                self.showOnboarding()
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

        configureCloudCommandSync(enabled: AppSettings.shared.enableICloudCommandSync)
        iCloudSyncObserver = NotificationCenter.default.addObserver(
            forName: .iCloudCommandSyncPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configureCloudCommandSync(enabled: AppSettings.shared.enableICloudCommandSync)
            }
        }
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

            guard !capture.text.isEmpty || !capture.images.isEmpty else {
                logger.info("No text or images selected for command: \(command.name)")
                return
            }

            logger.debug("Captured selection for command \(command.name) (text length: \(capture.text.count), images: \(capture.images.count))")

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
            let input = try await appState.resolveCommandInput(mode: .textOrImagesWithOCRFallback)

            // Get the appropriate provider for this command (respects per-command overrides)
            let provider = appState.getProvider(for: command)

            var result = try await provider.processText(
                systemPrompt: command.prompt,
                userPrompt: input.userPrompt,
                images: input.images,
                streaming: false
            )

            // Preserve trailing newlines from the original selection
            // This is important for triple-click selections which include the trailing newline
            let originalText = appState.selectedText
            if input.source == .selectedText, originalText.hasSuffix("\n"), !result.hasSuffix("\n") {
                result += "\n"
                logger.debug("Added trailing newline to match input")
            }

            await MainActor.run {
                let shouldUseResponseWindow = command.useResponseWindow || input.source == .imageOCRFallback
                if shouldUseResponseWindow {
                    let window = ResponseWindow(
                        title: command.name,
                        content: result,
                        selectedText: input.source == .selectedText ? appState.selectedText : "Image selection (OCR)",
                        option: nil,
                        provider: provider
                    )

                    WindowManager.shared.addResponseWindow(window)
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

            let alert = NSAlert()
            alert.messageText = "Command Error"
            alert.informativeText = "Failed to process '\(command.name)': \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")

            NSApp.activate()
            if let keyWindow = NSApp.keyWindow {
                await alert.beginSheetModal(for: keyWindow)
            } else {
                alert.runModal()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name("CommandsChanged"),
            object: nil
        )
        if let iCloudSyncObserver {
            NotificationCenter.default.removeObserver(iCloudSyncObserver)
            self.iCloudSyncObserver = nil
        }
        CloudCommandsSync.shared.stop()
        WindowManager.shared.cleanupWindows()
    }

    private func performRecoveryReset() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)

        WindowManager.shared.cleanupWindows()

        let alert = NSAlert()
        alert.messageText = "Recovery Complete"
        alert.informativeText =
            "The app has been reset to its default state."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        
        NSApp.activate()
        if let keyWindow = NSApp.keyWindow {
            alert.beginSheetModal(for: keyWindow)
        } else {
            alert.runModal()
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
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func closePopupWindow() {
        WindowManager.shared.dismissPopup()
    }

    private func configureCloudCommandSync(enabled: Bool) {
        CloudCommandsSync.shared.setEnabled(enabled)
        logger.info("iCloud command sync \(enabled ? "enabled" : "disabled")")
    }

}

extension AppDelegate {
    override func awakeFromNib() {
        super.awakeFromNib()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }
}

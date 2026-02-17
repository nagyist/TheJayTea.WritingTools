import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

private let logger = AppLogger.logger("AppDelegate")

/// AppDelegate handles keyboard shortcuts, services, and popup window management.
/// Menu bar UI is handled by SwiftUI's MenuBarExtra in writing_toolsApp.swift.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var iCloudSyncObserver: NSObjectProtocol?
    private var iCloudQuotaObserver: NSObjectProtocol?
    private var clipboardRestoreObserver: NSObjectProtocol?
    
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

        iCloudQuotaObserver = NotificationCenter.default.addObserver(
            forName: .iCloudCommandSyncQuotaExceeded,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let payloadBytes = note.userInfo?[CloudCommandsSyncUserInfoKey.payloadBytes] as? Int
                self.showICloudQuotaWarningAlert(payloadBytes: payloadBytes)
            }
        }

        clipboardRestoreObserver = NotificationCenter.default.addObserver(
            forName: .clipboardRestoreSkipped,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let expected = note.userInfo?[ClipboardNotificationUserInfoKey.expectedChangeCount] as? Int ?? -1
                let actual = note.userInfo?[ClipboardNotificationUserInfoKey.actualChangeCount] as? Int ?? -1
                self.showClipboardRestoreSkippedWarningAlert(
                    expectedChangeCount: expected,
                    actualChangeCount: actual
                )
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
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                _ = try await CommandExecutionEngine.shared.executeCommand(
                    command,
                    source: .hotkey
                )
            } catch let error as CommandExecutionEngineError {
                self.handleCommandExecutionError(error)
            } catch {
                logger.error("Error processing command \(command.name): \(error.localizedDescription)")
                await self.presentCommandErrorAlert(commandName: command.name, error: error)
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
        if let iCloudQuotaObserver {
            NotificationCenter.default.removeObserver(iCloudQuotaObserver)
            self.iCloudQuotaObserver = nil
        }
        if let clipboardRestoreObserver {
            NotificationCenter.default.removeObserver(clipboardRestoreObserver)
            self.clipboardRestoreObserver = nil
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

    private func handleCommandExecutionError(_ error: CommandExecutionEngineError) {
        switch error {
        case .captureInProgress:
            logger.debug("Clipboard capture skipped because another operation is in progress")
        case .noNewCopiedContent(let commandName):
            logger.warning("No new content was copied for command: \(commandName)")
        case .emptySelection(let commandName):
            logger.info("No text or images selected for command: \(commandName)")
        case .emptyInstruction:
            logger.warning("Custom instruction execution failed due to empty instruction")
        }
    }

    private func presentCommandErrorAlert(commandName: String, error: Error) async {
        let alert = NSAlert()
        alert.messageText = "Command Error"
        alert.informativeText = "Failed to process '\(commandName)': \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.activate()
        if let keyWindow = NSApp.keyWindow {
            await alert.beginSheetModal(for: keyWindow)
        } else {
            alert.runModal()
        }
    }

    private func closePopupWindow() {
        WindowManager.shared.dismissPopup()
    }

    private func configureCloudCommandSync(enabled: Bool) {
        CloudCommandsSync.shared.setEnabled(enabled)
        logger.info("iCloud command sync \(enabled ? "enabled" : "disabled")")
    }

    private func showICloudQuotaWarningAlert(payloadBytes: Int?) {
        let alert = NSAlert()
        alert.messageText = "iCloud Sync Storage Limit Reached"
        if let payloadBytes {
            alert.informativeText =
                """
                Writing Tools couldn't sync commands because iCloud key-value storage quota was exceeded (payload size: \(payloadBytes) bytes).
                Try deleting some commands or shortening large prompts, then sync again.
                """
        } else {
            alert.informativeText =
                """
                Writing Tools couldn't sync commands because iCloud key-value storage quota was exceeded.
                Try deleting some commands or shortening large prompts, then sync again.
                """
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.activate()
        if let keyWindow = NSApp.keyWindow {
            alert.beginSheetModal(for: keyWindow)
        } else {
            alert.runModal()
        }
    }

    private func showClipboardRestoreSkippedWarningAlert(
        expectedChangeCount: Int,
        actualChangeCount: Int
    ) {
        let alert = NSAlert()
        alert.messageText = "Clipboard Was Updated by Another App"
        alert.informativeText =
            """
            Writing Tools captured your selection, but your clipboard changed before it could be restored.
            Your latest clipboard content was preserved.
            (Expected change count: \(expectedChangeCount), actual: \(actualChangeCount))
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        NSApp.activate()
        if let keyWindow = NSApp.keyWindow {
            alert.beginSheetModal(for: keyWindow)
        } else {
            alert.runModal()
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

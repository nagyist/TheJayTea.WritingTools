import SwiftUI
import AppKit

private let logger = AppLogger.logger("WindowManager")

@MainActor
class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var onboardingWindow =
        NSMapTable<NSWindow, NSHostingView<OnboardingView>>.strongToWeakObjects()
    private var settingsWindow =
        NSMapTable<NSWindow, NSHostingView<SettingsView>>.strongToWeakObjects()

    // Track a single PopupWindow
    private weak var popupWindow: PopupWindow?

    private var responseWindows = NSHashTable<ResponseWindow>.weakObjects()

    // MARK: - Response Windows

    func addResponseWindow(_ window: ResponseWindow) {
        guard !window.isReleasedWhenClosed else {
            logger.error("Attempted to add a released window.")
            return
        }
        if !responseWindows.contains(window) {
            responseWindows.add(window)
            window.delegate = self
        }
        bringWindowToFront(window)
    }

    /// Activates the app and brings the given window to the front.
    ///
    /// Accessory apps (`NSApp.activationPolicy == .accessory`) don't appear in the
    /// Dock, so `NSApp.activate()` alone may not suffice. `orderFrontRegardless()`
    /// ensures the window appears above other apps even if activation is delayed.
    func bringWindowToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func removeResponseWindow(_ window: ResponseWindow) {
        responseWindows.remove(window)
    }

    // MARK: - Popup Window

    func registerPopupWindow(_ window: PopupWindow) {
        popupWindow = window
        window.delegate = self
    }

    func dismissPopup(clearImages: Bool = true) {
        if let window = self.popupWindow {
            window.close()
            self.popupWindow = nil
        }

        if clearImages {
            AppState.shared.selectedImages = []
        }
    }

    // MARK: - Onboarding & Settings

    func transitionFromOnboardingToSettings(appState: AppState) {
        let currentOnboardingWindow =
            onboardingWindow.keyEnumerator().nextObject() as? NSWindow

        let newSettingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        newSettingsWindow.title = "Complete Setup"
        newSettingsWindow.identifier = NSUserInterfaceItemIdentifier("SettingsWindow")
        newSettingsWindow.isReleasedWhenClosed = false
        newSettingsWindow.minSize = NSSize(width: 520, height: 440)

        let settingsView =
            SettingsView(appState: appState, showOnlyApiSetup: true)
        let hostingView = NSHostingView(rootView: settingsView)
        newSettingsWindow.contentView = hostingView
        newSettingsWindow.delegate = self

        settingsWindow.setObject(hostingView, forKey: newSettingsWindow)

        // Center window BEFORE display
        newSettingsWindow.level = .normal
        newSettingsWindow.center()
        
        NSApp.activate()
        newSettingsWindow.makeKeyAndOrderFront(nil)
        
        currentOnboardingWindow?.close()
        onboardingWindow.removeAllObjects()
    }

    func setOnboardingWindow(
        _ window: NSWindow,
        hostingView: NSHostingView<OnboardingView>
    ) {
        onboardingWindow.removeAllObjects()
        onboardingWindow.setObject(hostingView, forKey: window)
        window.delegate = self
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")
        
        window.center()
    }

    func registerSettingsWindow(
        _ window: NSWindow,
        hostingView: NSHostingView<SettingsView>
    ) {
        settingsWindow.removeAllObjects()
        settingsWindow.setObject(hostingView, forKey: window)
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("SettingsWindow")
    }

    func closeSettingsWindow() {
        if let window = settingsWindow.keyEnumerator().nextObject() as? NSWindow {
            window.close()
            settingsWindow.removeAllObjects()
        }
    }

    func showOnboarding(appState: AppState, title: String = "Welcome to Writing Tools") {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 600)

        let onboardingView = OnboardingView(appState: appState)
        let hostingView = NSHostingView(rootView: onboardingView)
        window.contentView = hostingView
        window.level = .floating

        setOnboardingWindow(window, hostingView: hostingView)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window Delegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let isOnboardingWindow = onboardingWindow.object(forKey: window) != nil
        let preferredLevel: NSWindow.Level
        if window is PopupWindow {
            preferredLevel = .popUpMenu
        } else if isOnboardingWindow {
            preferredLevel = .floating
        } else {
            preferredLevel = .normal
        }
        if window.level != preferredLevel {
            window.level = preferredLevel
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? PopupWindow else { return }
        // Auto-dismiss popup when it loses focus (e.g., user clicks elsewhere)
        // Skip if a sheet is being presented (e.g., command editor)
        if window.attachedSheet == nil {
            dismissPopup()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if let popup = window as? PopupWindow {
            popup.cleanup()
            if popupWindow === popup {
                popupWindow = nil
            }
        } else if let responseWindow = window as? ResponseWindow {
            removeResponseWindow(responseWindow)
        } else if onboardingWindow.object(forKey: window) != nil {
            onboardingWindow.removeObject(forKey: window)
        } else if settingsWindow.object(forKey: window) != nil {
            settingsWindow.removeObject(forKey: window)
        }

        window.delegate = nil
    }

    // MARK: - Cleanup

    func cleanupWindows() {
        let windowsToClose = getAllWindows()

        windowsToClose.forEach { window in
            // Set delegate to nil to prevent callbacks during close
            window.delegate = nil
            window.close()
        }
        clearAllWindows()
    }

    private func getAllWindows() -> [NSWindow] {
        var windows: [NSWindow] = []

        if let onboardingWindow =
            onboardingWindow.keyEnumerator().nextObject() as? NSWindow {
            windows.append(onboardingWindow)
        }

        if let settingsWindow =
            settingsWindow.keyEnumerator().nextObject() as? NSWindow {
            windows.append(settingsWindow)
        }

        if let popup = popupWindow {
            windows.append(popup)
        }

        windows.append(contentsOf: responseWindows.allObjects)
        return windows
    }

    private func clearAllWindows() {
        onboardingWindow.removeAllObjects()
        settingsWindow.removeAllObjects()
        responseWindows.removeAllObjects()
        popupWindow = nil
    }

    deinit {}
}

extension WindowManager {
    enum WindowError: LocalizedError {
        case windowCreationFailed
        case invalidWindowType
        case windowNotFound

        var errorDescription: String? {
            switch self {
            case .windowCreationFailed:
                return "Failed to create window"
            case .invalidWindowType:
                return "Invalid window type"
            case .windowNotFound:
                return "Window not found"
            }
        }
    }
}

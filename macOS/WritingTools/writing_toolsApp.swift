import SwiftUI

@main
struct writing_toolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.shared
    @State private var settings = AppSettings.shared
    
    var body: some Scene {
        // Menu bar extra provides the status item and dropdown menu
        MenuBarExtra("Writing Tools", systemImage: "pencil.circle") {
            MenuBarMenu(appState: appState, settings: settings)
        }
        .menuBarExtraStyle(.menu)
        
        // Settings scene for the preferences window
        Settings {
            SettingsView(appState: AppState.shared, showOnlyApiSetup: false)
        }
    }
}

// MARK: - Menu Bar Menu Content

struct MenuBarMenu: View {
    @Bindable var appState: AppState
    @Bindable var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        // Settings - use Button with openSettings to ensure proper activation
        Button("Settings") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        
        Button("About Writing Tools") {
            showAboutWindow()
        }
        
        Button(settings.hotkeysPaused ? "Resume Hotkeys" : "Pause Hotkeys") {
            settings.hotkeysPaused.toggle()
        }
        
        Divider()
        
        Button("Reset App") {
            confirmResetApp()
        }
        
        Divider()
        
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
    
    private func showAboutWindow() {
        // Activate app first to ensure window becomes active
        NSApp.activate()
        
        // Find existing about window or create new one
        if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "AboutWindow" }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("AboutWindow")
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "About Writing Tools"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    private func confirmResetApp() {
        let alert = NSAlert()
        alert.messageText = "Reset Writing Tools?"
        alert.informativeText = "This will reset windows and UI state. Your commands and settings will remain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            resetApp()
        }
    }
    
    private func resetApp() {
        WindowManager.shared.cleanupWindows()
        
        let alert = NSAlert()
        alert.messageText = "App Reset Complete"
        alert.informativeText = "The app has been reset. If you're still experiencing issues, try restarting the app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

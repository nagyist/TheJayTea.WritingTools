import SwiftUI
import Observation

class PopupWindow: NSWindow {
  private var initialLocation: NSPoint?
  private var retainedHostingView: NSHostingView<PopupWindowContentView>?
  private var trackingArea: NSTrackingArea?
  private let appState: AppState
  private let windowWidth: CGFloat = 305

  private let viewModel = PopupViewModel()
  
  init(appState: AppState) {
    self.appState = appState

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 100),
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )

    self.isReleasedWhenClosed = false

    configureWindow()
    setupTrackingArea()

    Task { @MainActor [weak self] in
      self?.updateWindowSize()
    }
  }

  private func configureWindow() {
    backgroundColor = .clear
    isOpaque = false
    level = .floating
    collectionBehavior = [.transient, .ignoresCycle]
    hasShadow = false

    let closeAction: () -> Void = { [weak self] in
      self?.close()
      self?.appState.previousApplication?.activate()
    }
    
    // Use a wrapper view that observes changes and triggers window size updates
    let contentView = PopupWindowContentView(
      appState: appState,
      viewModel: viewModel,
      closeAction: closeAction,
      onSizeChange: { [weak self] in
        self?.updateWindowSize()
      }
    )

    let hostingView = FirstResponderHostingView(rootView: contentView)
    hostingView.wantsLayer = true
    hostingView.layer?.cornerRadius = 20
    hostingView.layer?.maskedCorners = [
      .layerMinXMinYCorner,
      .layerMaxXMinYCorner,
      .layerMinXMaxYCorner,
      .layerMaxXMaxYCorner,
    ]
    hostingView.layer?.masksToBounds = true

    self.contentView = hostingView
    retainedHostingView = hostingView

    initialFirstResponder = hostingView
    makeFirstResponder(hostingView)
    makeKey()

    updateWindowSize()

    // Register with WindowManager for lifecycle management/cleanup
    WindowManager.shared.registerPopupWindow(self)
  }

  @objc private func updateWindowSize() {
    // Use a shorter delay only when needed for layout stabilization
    // For edit mode changes, we want immediate response
    let delay: Duration = self.viewModel.isEditMode ? .milliseconds(50) : .milliseconds(100)

    Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self else { return }

      let baseHeight: CGFloat = 100
      let buttonHeight: CGFloat = 55
      let spacing: CGFloat = 10
      let editButtonHeight: CGFloat = 60

      let totalCommands = self.appState.commandManager.commands.count
      let hasContent =
        !self.appState.selectedText.isEmpty
        || !self.appState.selectedImages.isEmpty
      let isEditMode = self.viewModel.isEditMode

      let numRows = hasContent ? ceil(Double(totalCommands) / 2.0) : 0

      var contentHeight: CGFloat = baseHeight

      if hasContent {
        contentHeight += (buttonHeight * CGFloat(numRows)) + spacing
        if isEditMode {
          contentHeight += editButtonHeight
        }
      }

        await NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        self.animator()
          .setContentSize(
            NSSize(width: self.windowWidth, height: contentHeight)
          )

        if let screen = self.screen {
          var frame = self.frame
          frame.size.height = contentHeight

          if frame.maxY > screen.visibleFrame.maxY {
            frame.origin.y = screen.visibleFrame.maxY - frame.height
          }

          self.animator().setFrame(frame, display: true)
        }
      }
    }
  }


  private func setupTrackingArea() {
    guard let contentView = contentView else { return }

    if let existing = trackingArea {
      contentView.removeTrackingArea(existing)
    }

    trackingArea = NSTrackingArea(
      rect: contentView.bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .mouseMoved],
      owner: self,
      userInfo: nil
    )

    if let trackingArea = trackingArea {
      contentView.addTrackingArea(trackingArea)
    }
  }

  func cleanup() {
    if let contentView = contentView, let trackingArea = trackingArea {
      contentView.removeTrackingArea(trackingArea)
      self.trackingArea = nil
    }

    if let hostingView = retainedHostingView {
      hostingView.removeFromSuperview()
      self.retainedHostingView = nil
    }

    self.delegate = nil

    self.contentView = nil
  }

  override func close() {
    cleanup()
    super.close()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  // Mouse Event Handling
  override func mouseDown(with event: NSEvent) {
    initialLocation = event.locationInWindow
  }

  override func mouseDragged(with event: NSEvent) {
    guard
      contentView != nil,
      let initialLocation = initialLocation,
      let screen = screen
    else { return }

    let currentLocation = event.locationInWindow
    let deltaX = currentLocation.x - initialLocation.x
    let deltaY = currentLocation.y - initialLocation.y

    var newOrigin = frame.origin
    newOrigin.x += deltaX
    newOrigin.y += deltaY

    let padding: CGFloat = 20
    let screenFrame = screen.visibleFrame
    newOrigin.x = max(
      screenFrame.minX + padding,
      min(newOrigin.x, screenFrame.maxX - frame.width - padding)
    )
    newOrigin.y = max(
      screenFrame.minY + padding,
      min(newOrigin.y, screenFrame.maxY - frame.height - padding)
    )

    setFrameOrigin(newOrigin)
  }

  override func mouseUp(with event: NSEvent) {
    initialLocation = nil
  }

  // Window Positioning

  func screenAt(point: NSPoint) -> NSScreen? {
    for screen in NSScreen.screens {
      if screen.frame.contains(point) {
        return screen
      }
    }
    return nil
  }

  func positionNearMouse() {
    let mouseLocation = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(mouseLocation)
      }) ?? NSScreen.main
    else { return }

    let padding: CGFloat = 10
    var windowFrame = frame
    windowFrame.size.width = windowWidth

    windowFrame.origin.x = mouseLocation.x - (windowWidth / 2)
    windowFrame.origin.y = mouseLocation.y - windowFrame.height - padding

    windowFrame.origin.x = max(
      screen.visibleFrame.minX + padding,
      min(
        windowFrame.origin.x,
        screen.visibleFrame.maxX - windowWidth - padding
      )
    )

    if windowFrame.minY < screen.visibleFrame.minY {
      windowFrame.origin.y = mouseLocation.y + padding
    }

    setFrame(windowFrame, display: true)
  }

  // Close via ESC Key
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      self.close()
    } else {
      super.keyDown(with: event)
    }
  }
}

extension PopupWindow: NSWindowDelegate {
  func windowDidBecomeKey(_ notification: Notification) {
    level = .popUpMenu
  }
}

class FirstResponderHostingView<Content: View>: NSHostingView<Content> {
  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

// MARK: - SwiftUI Wrapper for Observation

/// A wrapper view that observes state changes using SwiftUI's native observation
/// and triggers window size updates via a callback. This replaces manual
/// observation loops with cleaner SwiftUI patterns.
struct PopupWindowContentView: View {
  @Bindable var appState: AppState
  @Bindable var viewModel: PopupViewModel
  let closeAction: () -> Void
  let onSizeChange: () -> Void
  
  var body: some View {
    PopupView(
      appState: appState,
      viewModel: viewModel,
      closeAction: closeAction
    )
    // Use SwiftUI's native onChange to observe state changes
    .onChange(of: appState.commandManager.commands.count) { _, _ in
      onSizeChange()
    }
    .onChange(of: viewModel.isEditMode) { _, _ in
      onSizeChange()
    }
  }
}

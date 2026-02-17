import AppKit

private let logger = AppLogger.logger("CommandExecutionEngine")

enum CommandExecutionEngineError: LocalizedError {
  case emptyInstruction
  case captureInProgress
  case noNewCopiedContent(commandName: String)
  case emptySelection(commandName: String)

  var errorDescription: String? {
    switch self {
    case .emptyInstruction:
      return "Instruction cannot be empty."
    case .captureInProgress:
      return "Clipboard capture is already in progress."
    case .noNewCopiedContent(let commandName):
      return "No new content was copied for command: \(commandName)"
    case .emptySelection(let commandName):
      return "No text or images selected for command: \(commandName)"
    }
  }
}

@MainActor
final class CommandExecutionEngine {
  enum ExecutionSource {
    case popup
    case hotkey
  }

  enum ExecutionOutcome {
    case completedInline
    case openedResponseWindow
    case skippedBecauseBusy
  }

  static let shared = CommandExecutionEngine(appState: AppState.shared)

  private let appState: AppState

  private init(appState: AppState) {
    self.appState = appState
  }

  @discardableResult
  func executeCommand(
    _ command: CommandModel,
    source: ExecutionSource,
    closePopupOnInlineCompletion: (() -> Void)? = nil
  ) async throws -> ExecutionOutcome {
    guard !appState.isProcessing else {
      logger.debug("Command ignored because a request is already in progress.")
      return .skippedBecauseBusy
    }

    appState.isProcessing = true
    defer { appState.isProcessing = false }

    try await prepareSelectionIfNeeded(for: source, commandName: command.name)

    let input = try await appState.resolveCommandInput(mode: .textOrImagesWithOCRFallback)
    let provider = appState.getProvider(for: command)
    let shouldUseResponseWindow = command.useResponseWindow || input.source == .imageOCRFallback

    if shouldUseResponseWindow {
      let selectedText = input.source == .selectedText ? appState.selectedText : "Image selection (OCR)"
      openStreamingResponseWindow(
        title: command.name,
        selectedText: selectedText,
        provider: provider,
        systemPrompt: command.prompt,
        userPrompt: input.userPrompt,
        images: input.images,
        continuationSystemPrompt: command.prompt,
        source: source
      )
      return .openedResponseWindow
    }

    var result = try await provider.processText(
      systemPrompt: command.prompt,
      userPrompt: input.userPrompt,
      images: input.images,
      streaming: false
    )

    if input.source == .selectedText {
      result = normalizedInlineReplacement(
        result,
        originalSelectedText: appState.selectedText
      )
    }

    if command.preserveFormatting, appState.selectedAttributedText != nil {
      appState.replaceSelectedTextPreservingAttributes(with: result)
    } else {
      appState.replaceSelectedText(with: result)
    }

    if source == .popup {
      closePopupOnInlineCompletion?()
    }

    return .completedInline
  }

  @discardableResult
  func executeCustomInstruction(
    _ instruction: String,
    source: ExecutionSource,
    openInResponseWindow: Bool,
    closePopupOnInlineCompletion: (() -> Void)? = nil
  ) async throws -> ExecutionOutcome {
    let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInstruction.isEmpty else {
      throw CommandExecutionEngineError.emptyInstruction
    }

    guard !appState.isProcessing else {
      logger.debug("Custom instruction ignored because a request is already in progress.")
      return .skippedBecauseBusy
    }

    appState.isProcessing = true
    defer { appState.isProcessing = false }

    try await prepareSelectionIfNeeded(for: source, commandName: "Custom Instruction")

    let systemPrompt = Self.customInstructionSystemPrompt
    let selectedText = appState.selectedText
    let userPrompt = selectedText.isEmpty
      ? trimmedInstruction
      : """
        User's instruction: \(trimmedInstruction)

        Text:
        \(selectedText)
        """

    if openInResponseWindow {
      openStreamingResponseWindow(
        title: "AI Response",
        selectedText: selectedText.isEmpty ? trimmedInstruction : selectedText,
        provider: appState.activeProvider,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        images: appState.selectedImages,
        continuationSystemPrompt: systemPrompt,
        source: source
      )
      return .openedResponseWindow
    }

    var result = try await appState.activeProvider.processText(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      images: appState.selectedImages,
      streaming: false
    )

    result = normalizedInlineReplacement(
      result,
      originalSelectedText: selectedText
    )
    appState.replaceSelectedText(with: result)

    if source == .popup {
      closePopupOnInlineCompletion?()
    }

    return .completedInline
  }

  private func prepareSelectionIfNeeded(
    for source: ExecutionSource,
    commandName: String
  ) async throws {
    guard source == .hotkey else { return }

    let previousApp = NSWorkspace.shared.frontmostApplication
    guard let capture = await ClipboardCoordinator.shared.captureSelection() else {
      throw CommandExecutionEngineError.captureInProgress
    }

    guard capture.didChange else {
      throw CommandExecutionEngineError.noNewCopiedContent(commandName: commandName)
    }

    guard !capture.text.isEmpty || !capture.images.isEmpty else {
      throw CommandExecutionEngineError.emptySelection(commandName: commandName)
    }

    logger.debug(
      """
      Captured selection for \(commandName) \
      (text length: \(capture.text.count), images: \(capture.images.count))
      """
    )

    appState.selectedImages = capture.images
    appState.selectedAttributedText = capture.attributedText
    appState.selectedText = capture.text

    if let previousApp {
      appState.previousApplication = previousApp
    }
  }

  private func normalizedInlineReplacement(
    _ output: String,
    originalSelectedText: String
  ) -> String {
    guard originalSelectedText.hasSuffix("\n"), !output.hasSuffix("\n") else {
      return output
    }
    logger.debug("Added trailing newline to match input")
    return output + "\n"
  }

  private func openStreamingResponseWindow(
    title: String,
    selectedText: String,
    provider: any AIProvider,
    systemPrompt: String,
    userPrompt: String,
    images: [Data],
    continuationSystemPrompt: String,
    source: ExecutionSource
  ) {
    let window = ResponseWindow(
      title: title,
      selectedText: selectedText,
      option: nil,
      provider: provider,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      images: images,
      continuationSystemPrompt: continuationSystemPrompt
    )

    if source == .popup {
      // Keep response windows frontmost when launched from popup actions.
      WindowManager.shared.dismissPopup(clearImages: false)
    }

    WindowManager.shared.addResponseWindow(window)
  }

  private static let customInstructionSystemPrompt = """
    You are a writing and coding assistant. Your sole task is to respond \
    to the user's instruction thoughtfully and comprehensively.
    If the instruction is a question, provide a detailed answer. But \
    always return the best and most accurate answer and not different \
    options.
    If it's a request for help, provide clear guidance and examples where \
    appropriate. Make sure to use the language used or specified by the \
    user instruction.
    Use Markdown formatting to make your response more readable.
    """
}

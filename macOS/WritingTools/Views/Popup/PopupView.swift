import SwiftUI
import ApplicationServices
import Observation

private let logger = AppLogger.logger("PopupView")

@MainActor
@Observable
final class PopupViewModel {
  var isEditMode: Bool = false
}

struct PopupView: View {
  @Bindable var appState: AppState
  @Bindable var viewModel: PopupViewModel
  @Environment(\.colorScheme) var colorScheme
  @AppStorage("use_gradient_theme") private var useGradientTheme = false

  @State private var customText: String = ""
  @State private var isCustomLoading: Bool = false
  @State private var processingCommandId: UUID? = nil

  @State private var showingCommandsView = false
  @State private var editingCommand: CommandModel? = nil

  // Error handling
  @State private var showingErrorAlert = false
  @State private var errorMessage = ""
  
  // Focus management for accessibility
  @FocusState private var isTextFieldFocused: Bool

  let closeAction: () -> Void

  // Grid layout for two columns
  private let columns = [
    GridItem(.flexible(), spacing: 8),
    GridItem(.flexible(), spacing: 8),
  ]

  var body: some View {
    VStack(spacing: 16) {
      // Top bar with buttons
      HStack {
        Button(action: {
          if viewModel.isEditMode {
            viewModel.isEditMode = false
          } else {
            closeAction()
          }
        }) {
          Image(systemName: "xmark")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color(.controlBackgroundColor))
            .clipShape(.circle)
        }
        .buttonStyle(.plain)
        .help(viewModel.isEditMode ? "Exit Edit Mode" : "Close")
        .accessibilityLabel(viewModel.isEditMode ? "Exit edit mode" : "Close popup")
        .accessibilityHint(viewModel.isEditMode ? "Return to command list" : "Dismiss the popup")
        .padding(.top, 8)
        .padding(.leading, 8)

        Spacer()

        Button(action: {
          viewModel.isEditMode.toggle()
          // Note: PopupWindow observes viewModel.isEditMode directly via @Observable
        }) {
          Image(
            systemName: viewModel.isEditMode ? "checkmark" : "square.and.pencil"
          )
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(Color(.controlBackgroundColor))
          .clipShape(.circle)
        }
        .buttonStyle(.plain)
        .help(viewModel.isEditMode ? "Save Changes" : "Edit Commands")
        .accessibilityLabel(viewModel.isEditMode ? "Save changes" : "Edit commands")
        .accessibilityHint(viewModel.isEditMode ? "Exit edit mode" : "Edit command list")
        .padding(.top, 8)
        .padding(.trailing, 8)
      }

      // Custom input with send button
      if !viewModel.isEditMode {
        HStack(spacing: 8) {
          TextField(
            "Describe your change...",
            text: $customText
          )
          .textFieldStyle(.plain)
          .focused($isTextFieldFocused)
          .appleStyleTextField(
            text: customText,
            isLoading: isCustomLoading,
            onSubmit: processCustomChange
          )
          .accessibilityLabel("Custom instruction")
          .accessibilityHint("Describe how to modify the selected text")
        }
        .padding(.horizontal)
        .onAppear {
          // Auto-focus the text field when popup appears for better keyboard accessibility
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldFocused = true
          }
        }
      }

      if !appState.selectedText.isEmpty || !appState.selectedImages.isEmpty {
        // Command buttons grid
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(appState.commandManager.commands) { command in
            CommandButton(
              command: command,
              isEditing: viewModel.isEditMode,
              isLoading: processingCommandId == command.id,
              onTap: {
                processingCommandId = command.id
                Task {
                  await processCommandAndCloseWhenDone(command)
                }
              },
              onEdit: {
                editingCommand = command
              },
              onDelete: {
                logger.debug("Deleting command: \(command.name)")
                appState.commandManager.deleteCommand(command)
              }
            )
          }
        }
        .padding(.horizontal, 16)
      }

      if viewModel.isEditMode {
        Button(action: { showingCommandsView = true }) {
          HStack {
            Image(systemName: "plus.circle.fill")
            Text("Manage Commands")
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color(.controlBackgroundColor))
          .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
      }
    }
    .padding(.bottom, 8)
    .windowBackground(useGradient: useGradientTheme, cornerRadius: 20)
    .overlay(
      RoundedRectangle(cornerRadius: 20)
        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
    )
    .clipShape(.rect(cornerRadius: 20))
    .shadow(color: Color.black.opacity(0.2), radius: 10, y: 5)
    // Sheet for editing individual command
    .sheet(item: $editingCommand) { command in
      let binding = Binding(
        get: { command },
        set: { updatedCommand in
          appState.commandManager.updateCommand(updatedCommand)
          editingCommand = nil
        }
      )

      CommandEditor(
        command: binding,
        onSave: {
          editingCommand = nil
        },
        onCancel: {
          editingCommand = nil
        },
        commandManager: appState.commandManager
      )
    }
    // Sheet for managing all commands
    .sheet(isPresented: $showingCommandsView) {
      CommandsView(commandManager: appState.commandManager)
      // Note: PopupWindow observes commandManager.commands directly via @Observable
    }
    .alert("Error", isPresented: $showingErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
  }

  // Process a command asynchronously and only close the popup when done
  private func processCommandAndCloseWhenDone(
    _ command: CommandModel
  ) async {
    guard !appState.isProcessing else {
      processingCommandId = nil
      return
    }

    appState.isProcessing = true

    do {
      let systemPrompt = command.prompt
      let input = try await appState.resolveCommandInput(mode: .textOrImagesWithOCRFallback)
      let userText = appState.selectedText

      // Get the appropriate provider for this command (respects per-command overrides)
      let provider = appState.getProvider(for: command)

      let result = try await provider.processText(
        systemPrompt: systemPrompt,
        userPrompt: input.userPrompt,
        images: input.images,
        streaming: false
      )

      await MainActor.run {
        let shouldUseResponseWindow = command.useResponseWindow || input.source == .imageOCRFallback
        if shouldUseResponseWindow {
          let window = ResponseWindow(
            title: command.name,
            content: result,
            selectedText: input.source == .selectedText ? userText : "Image selection (OCR)",
            option: .proofread,
            provider: provider
          )

          WindowManager.shared.addResponseWindow(window)
          window.makeKeyAndOrderFront(nil)
          window.orderFrontRegardless()
        } else {
          if command.preserveFormatting {
            appState.replaceSelectedTextPreservingAttributes(with: result)
          } else {
            appState.replaceSelectedText(with: result)
          }
        }

        closeAction()
        processingCommandId = nil
      }
    } catch {
      logger.error("Error processing command: \(error.localizedDescription)")
      await MainActor.run {
        errorMessage = error.localizedDescription
        showingErrorAlert = true
        processingCommandId = nil
      }
    }

    await MainActor.run {
      appState.isProcessing = false
    }
  }

  private func processCustomChange() {
    guard !customText.isEmpty, !appState.isProcessing else { return }
    isCustomLoading = true
    processCustomInstruction(customText)
  }

  private func processCustomInstruction(_ instruction: String) {
    guard !instruction.isEmpty, !appState.isProcessing else { return }
    appState.isProcessing = true

    // Capture setting value once at the start
    let openInResponseWindow = AppSettings.shared.openCustomCommandsInResponseWindow

    Task {
      do {
        let systemPrompt = """
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

        let userPrompt = appState.selectedText.isEmpty
          ? instruction
          : """
            User's instruction: \(instruction)

            Text:
            \(appState.selectedText)
            """

        let result = try await appState.activeProvider.processText(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          images: appState.selectedImages,
          streaming: false
        )

        await MainActor.run {
          if openInResponseWindow {
            let window = ResponseWindow(
              title: "AI Response",
              content: result,
              selectedText: appState.selectedText.isEmpty
                ? instruction : appState.selectedText,
              option: .proofread,
              provider: appState.activeProvider
            )

            WindowManager.shared.addResponseWindow(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
          } else {
            appState.replaceSelectedText(with: result)
          }

          customText = ""
          isCustomLoading = false
          closeAction()
        }
      } catch {
        logger.error("Error processing text: \(error.localizedDescription)")
        await MainActor.run {
          errorMessage = error.localizedDescription
          showingErrorAlert = true
          isCustomLoading = false
        }
      }

      appState.isProcessing = false
    }
  }
}
// MARK: - Preview

#Preview("Popup View - Default") {
  @Previewable @State var appState = {
    let state = AppState.shared
    state.selectedText = """
      This is some sample text that has been selected by the user. \
      It could be a paragraph from a document, an email, or any other text \
      that needs to be processed by the AI writing tools.
      """
    return state
  }()
  
  @Previewable @State var viewModel = PopupViewModel()
  
  PopupView(
    appState: appState,
    viewModel: viewModel,
    closeAction: {
      print("Close action triggered")
    }
  )
  .frame(width: 400, height: 500)
}
/*
#Preview("Popup View - Edit Mode") {
  @Previewable @State var appState = {
    let state = AppState.shared
    state.selectedText = "Sample text for editing commands."
    return state
  }()
  
  @Previewable @State var viewModel = {
    let vm = PopupViewModel()
    vm.isEditMode = true
    return vm
  }()
  
  PopupView(
    appState: appState,
    viewModel: viewModel,
    closeAction: {
      print("Close action triggered")
    }
  )
  .frame(width: 400, height: 500)
}

#Preview("Popup View - No Selection") {
  @Previewable @State var appState = AppState.shared
  @Previewable @State var viewModel = PopupViewModel()
  
  PopupView(
    appState: appState,
    viewModel: viewModel,
    closeAction: {
      print("Close action triggered")
    }
  )
  .frame(width: 400, height: 500)
}

#Preview("Popup View - With Images") {
  @Previewable @State var appState = {
    let state = AppState.shared
    state.selectedText = "Analyze this image and text together."
    // Mock image data
    if let mockImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
       let tiffData = mockImage.tiffRepresentation {
      state.selectedImages = [tiffData]
    }
    return state
  }()
  
  @Previewable @State var viewModel = PopupViewModel()
  
  PopupView(
    appState: appState,
    viewModel: viewModel,
    closeAction: {
      print("Close action triggered")
    }
  )
  .frame(width: 400, height: 500)
}
*/

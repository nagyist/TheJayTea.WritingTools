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
  @Bindable private var settings = AppSettings.shared
  @Environment(\.colorScheme) var colorScheme

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
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            isTextFieldFocused = true
          }
        }
      }

      if !appState.selectedText.isEmpty || !appState.selectedImages.isEmpty {
        commandButtonsGrid
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
    .windowBackground(useGradient: settings.useGradientTheme, cornerRadius: 20)
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
    // Suppress popup auto-dismiss while a sheet is presenting or presented.
    // This prevents a race where windowDidResignKey fires before the sheet
    // is attached to the window.
    .onChange(of: editingCommand) { _, newValue in
      WindowManager.shared.setPopupDismissSuppressed(
        newValue != nil,
        reason: .commandEditorSheet
      )
    }
    .onChange(of: showingCommandsView) { _, newValue in
      WindowManager.shared.setPopupDismissSuppressed(
        newValue,
        reason: .commandsManagerSheet
      )
    }
    .alert("Error", isPresented: $showingErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
  }

  // MARK: - Command Buttons Grid

  @ViewBuilder
  private var commandButtonsGrid: some View {
    let grid = LazyVGrid(columns: columns, spacing: 8) {
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

    if #available(macOS 26, *) {
      // GlassEffectContainer renders all glass effects in a single pass,
      // ensuring consistent background adaptation across all buttons.
      // spacing: 0 prevents shapes from blending into each other at rest.
      GlassEffectContainer(spacing: 0) {
        grid
      }
    } else {
      grid
    }
  }

  // Process a command asynchronously and only close the popup when done
  private func processCommandAndCloseWhenDone(
    _ command: CommandModel
  ) async {
    defer { processingCommandId = nil }

    do {
      _ = try await CommandExecutionEngine.shared.executeCommand(
        command,
        source: .popup,
        closePopupOnInlineCompletion: closeAction
      )
    } catch let error as CommandExecutionEngineError {
      logger.error("Error processing command: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    } catch {
      logger.error("Error processing command: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

  private func processCustomChange() {
    let instruction = customText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty else { return }
    isCustomLoading = true
    Task {
      await processCustomInstruction(instruction)
    }
  }

  private func processCustomInstruction(_ instruction: String) async {
    defer { isCustomLoading = false }

    do {
      let outcome = try await CommandExecutionEngine.shared.executeCustomInstruction(
        instruction,
        source: .popup,
        openInResponseWindow: AppSettings.shared.openCustomCommandsInResponseWindow,
        closePopupOnInlineCompletion: closeAction
      )
      if outcome != .skippedBecauseBusy {
        customText = ""
      }
    } catch let error as CommandExecutionEngineError {
      logger.error("Error processing text: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    } catch {
      logger.error("Error processing text: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
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

import SwiftUI

struct CommandButton: View {
    let command: CommandModel
    let isEditing: Bool
    let isLoading: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        ZStack {
            
            // Overlay edit controls when in edit mode
            if isEditing {
                HStack {
                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .frame(width: 10, height: 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("Delete \(command.name)")
                    .accessibilityHint("Removes this command")
                    
                    Spacer()
                    
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .frame(width: 10, height: 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Edit \(command.name)")
                    .accessibilityHint("Edit this command's details")
                }
                .padding(.horizontal, 4)
            }
            
            // Main button wrapper
            Button(action: {
                if !isEditing && !isLoading {
                    onTap()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: command.icon)
                    Text(command.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .contentShape(Rectangle())
            }
            .buttonStyle(LoadingButtonStyle(isLoading: isLoading))
            .opacity(isEditing ? 0 : 1)
            .disabled(isLoading || isEditing)
            .accessibilityLabel(command.name)
            .accessibilityHint(isLoading ? "Processing" : "Apply \(command.name) to selected text")
            .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
            
            
        }
        .commandButtonBackground()
    }
}

// MARK: - Command Button Background

/// Applies the correct background style based on OS version:
/// Liquid Glass on macOS 26+, solid color on older versions.
/// The glass effect is applied directly as a view modifier (not inside
/// .background {}) so the system correctly renders the Liquid Glass
/// material behind the view's content without double-blurring.
private struct CommandButtonBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
        } else {
            content
                .background(
                    Color(.controlBackgroundColor)
                        .clipShape(.rect(cornerRadius: 8))
                )
        }
    }
}

extension View {
    func commandButtonBackground() -> some View {
        modifier(CommandButtonBackgroundModifier())
    }
}

struct LoadingButtonStyle: ButtonStyle {
    var isLoading: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isLoading ? 0.5 : 1.0)
            .overlay(
                Group {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
            )
    }
}

#Preview {
    VStack {
        CommandButton(
            command: CommandModel.proofread,
            isEditing: false,
            isLoading: false,
            onTap: {},
            onEdit: {},
            onDelete: {}
        )
        
        CommandButton(
            command: CommandModel.proofread,
            isEditing: true,
            isLoading: false,
            onTap: {},
            onEdit: {},
            onDelete: {}
        )
    }
    .frame(width: 120)
}

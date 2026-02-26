import SwiftUI

struct AppleStyleTextFieldModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isLoading: Bool
    let text: String
    let onSubmit: () -> Void
    
    @State private var isAnimating: Bool = false
    @State private var isHovered: Bool = false
    
    private let animationDuration = 0.3
    private let animationDelay: Duration = .milliseconds(300)
    
    /// Returns nil when Reduce Motion is enabled to disable animations
    private var animation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: animationDuration)
    }
    
    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                content
                    .font(.system(size: 14))
                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                    .padding(12)
                    .onSubmit {
                        performSubmitAnimation()
                    }
                
                Spacer(minLength: 0)
            }
            
            // Integrated send button with more subtle styling
            if !text.isEmpty {
                Button(action: performSubmitAnimation) {
                    Image(systemName: isLoading ? "hourglass" : "paperplane.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .background(isLoading ? Color.gray : Color.blue)
                        .clipShape(.circle)
                        .scaleEffect(isHovered ? 1.05 : 1.0)
                        .opacity(isHovered ? 1.0 : 0.9)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .padding(.trailing, 8)
                .transition(.opacity)
                .onHover { hovering in
                    isHovered = hovering
                }
                .help(isLoading ? "Processing…" : "Send message")
                .accessibilityLabel(isLoading ? "Processing" : "Send message")
            }
        }
        .frame(height: 36)
        .background(
            ZStack {
                if colorScheme == .dark {
                    Color.black.opacity(0.2)
                        .blur(radius: 0.5)
                } else {
                    Color(.textBackgroundColor)
                }
                
                if isLoading {
                    Color.gray.opacity(0.1)
                }
            }
        )
        .clipShape(.rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isAnimating
                        ? Color.blue.opacity(0.8)
                        : Color.gray.opacity(0.2),
                    lineWidth: isAnimating ? 2 : 0.5
                )
                .animation(animation, value: isAnimating)
        )
    }
    
    private func performSubmitAnimation() {
        withAnimation(animation) {
            isAnimating = true
        }
        
        onSubmit()
        
        Task { @MainActor in
            // Skip delay if reduce motion is enabled
            if !reduceMotion {
                try? await Task.sleep(for: animationDelay)
            }
            withAnimation(animation) {
                isAnimating = false
            }
        }
    }
}

extension View {
    func appleStyleTextField(
        text: String,
        isLoading: Bool = false,
        onSubmit: @escaping () -> Void
    ) -> some View {
        self.modifier(AppleStyleTextFieldModifier(isLoading: isLoading, text: text, onSubmit: onSubmit))
    }
}

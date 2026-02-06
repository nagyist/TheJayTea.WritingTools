import SwiftUI

struct SecureAPIKeyField: View {
    private let title: String
    private let placeholder: String
    @Binding private var value: String
    @State private var isRevealed = false

    init(_ title: String, text: Binding<String>, placeholder: String = "API Key") {
        self.title = title
        self.placeholder = placeholder
        self._value = text
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $value)
                } else {
                    SecureField(placeholder, text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button(action: { isRevealed.toggle() }) {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide \(title)" : "Reveal \(title)")
            .accessibilityLabel(isRevealed ? "Hide \(title)" : "Reveal \(title)")
        }
    }
}

#Preview {
    @Previewable @State var key = ""
    SecureAPIKeyField("API Key", text: $key)
        .padding()
}

import SwiftUI

struct ChatBubbleModifier: ViewModifier {
    let isFromUser: Bool
    
    func body(content: Content) -> some View {
        let bubbleShape = ChatBubble(isFromUser: isFromUser)
        content
            .padding()
            .background(
                bubbleShape
                    .fill(isFromUser ? Color.blue.opacity(0.15) :  Color(.controlBackgroundColor))
            )
            .clipShape(bubbleShape)
    }
}

extension View {
    func chatBubbleStyle(isFromUser: Bool) -> some View {
        self.modifier(ChatBubbleModifier(isFromUser: isFromUser))
    }
}


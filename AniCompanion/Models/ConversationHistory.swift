import Foundation

/// In-memory conversation history with a sliding window for context management.
@MainActor
final class ConversationHistory: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    /// Maximum number of messages to keep in context window for LLM calls.
    /// Older messages are still displayed in UI but not sent to the LLM.
    let maxContextMessages: Int

    init(maxContextMessages: Int = 40) {
        self.maxContextMessages = maxContextMessages
    }

    func addMessage(_ message: ChatMessage) {
        messages.append(message)
    }

    func addUserMessage(_ content: String, isHidden: Bool = false) {
        addMessage(ChatMessage(role: .user, content: content, isHidden: isHidden))
    }

    func addAssistantMessage(_ content: String) {
        addMessage(ChatMessage(role: .assistant, content: content))
    }

    func addSystemMessage(_ content: String) {
        addMessage(ChatMessage(role: .system, content: content))
    }

    /// Messages to send to the LLM (most recent N messages).
    var contextMessages: [ChatMessage] {
        let startIndex = max(0, messages.count - maxContextMessages)
        return Array(messages[startIndex...])
    }

    func removeLastMessage() {
        guard !messages.isEmpty else { return }
        messages.removeLast()
    }

    func clear() {
        messages.removeAll()
    }
}

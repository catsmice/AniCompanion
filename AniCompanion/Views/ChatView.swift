import SwiftUI

// MARK: - ChatView

/// A chat interface displaying the conversation history with a text input bar at the bottom.
///
/// User messages appear right-aligned in blue bubbles; assistant messages appear
/// left-aligned in gray bubbles. Includes a text input field, send button, and
/// microphone button for voice input. Auto-scrolls to the latest message.
struct ChatView: View {

    @ObservedObject var conversationController: ConversationController
    @ObservedObject var conversationHistory: ConversationHistory

    /// The current text input value.
    @State private var inputText: String = ""

    /// Focus state for the text input field.
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Message List

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(conversationHistory.messages.filter { $0.role != .system && !$0.isHidden }) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }

                        // Streaming text or typing indicator (single view type for LazyVStack stability).
                        // Gated on `isStreaming` (not `isProcessing`) so the indicator disappears
                        // as soon as the response text is committed, rather than lingering through
                        // TTS playback while 小光 is still speaking.
                        if conversationController.isStreaming {
                            AssistantProcessingView(streamingText: conversationController.streamingText)
                                .id("typing-indicator")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .onChange(of: conversationHistory.messages.count) { _, _ in
                    scrollToBottom(proxy: scrollProxy)
                }
                .onChange(of: conversationController.isProcessing) { _, _ in
                    scrollToBottom(proxy: scrollProxy)
                }
                .onChange(of: conversationController.streamingText) { _, _ in
                    scrollToBottom(proxy: scrollProxy)
                }
            }

            // MARK: - Error Banner

            if let error = conversationController.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        conversationController.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // MARK: - Input Bar

            HStack(spacing: 8) {
                // Microphone button (push-to-talk). Disabled in full-duplex mode: there, the VPIO
                // engine owns the mic while she speaks, so opening STTService's engine here would
                // grab the same input device twice. In full-duplex you interrupt by just talking.
                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: conversationController.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(conversationController.isListening ? .red : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(conversationController.fullDuplexEnabled)
                .help(conversationController.fullDuplexEnabled
                    ? "Voice interruption is on — just talk to interrupt her"
                    : (conversationController.isListening
                        ? "Stop listening"
                        : (conversationController.isSpeaking ? "Interrupt & speak" : "Start voice input")))

                // Text input field
                TextField("Type a message...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }

                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? .blue : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
        .background(Color.clear)
        .onAppear {
            isInputFocused = true
        }
    }

    // MARK: - Helpers

    /// Whether the send button should be enabled.
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send the current input text as a message.
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        Task {
            await conversationController.sendMessage(text)
        }
    }

    /// Toggle voice input on or off.
    private func toggleVoiceInput() {
        if conversationController.isListening {
            conversationController.stopVoiceInput()
        } else {
            Task {
                await conversationController.startVoiceInput()
            }
        }
    }

    /// Scroll to the bottom of the message list.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if conversationController.isStreaming {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let lastMessage = conversationHistory.messages.last(where: { $0.role != .system && !$0.isHidden }) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - MessageBubbleView

/// A single chat message displayed as a rounded bubble.
///
/// User messages are right-aligned with a blue background; assistant messages
/// are left-aligned with a dark gray background.
private struct MessageBubbleView: View {

    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            // Role icon
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.purple.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .padding(.top, 4)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.displayContent)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isUser
                                ? Color.blue.opacity(0.6)
                                : Color.white.opacity(0.1)
                            )
                    )

                Text(formattedTimestamp)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            // User icon
            if isUser {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .padding(.top, 4)
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    /// Format the message timestamp for display.
    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - AssistantProcessingView

/// Combined view that shows either animated typing dots (waiting for first token)
/// or live streaming text. Uses a single view type so LazyVStack identity stays stable.
private struct AssistantProcessingView: View {

    let streamingText: String

    @State private var animating = false

    private var cleanedText: String {
        ConversationController.stripEmotionTags(from: streamingText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.purple.opacity(0.8))
                .frame(width: 24, height: 24)
                .padding(.top, 4)

            if cleanedText.isEmpty {
                // Typing dots — waiting for first token
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 6, height: 6)
                            .offset(y: animating ? -4 : 0)
                            .animation(
                                .easeInOut(duration: 0.5)
                                    .repeatForever()
                                    .delay(Double(index) * 0.15),
                                value: animating
                            )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.1))
                )
            } else {
                // Live streaming text
                Text(cleanedText)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.disabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                    )
            }

            Spacer(minLength: 40)
        }
        .onAppear {
            animating = true
        }
    }
}

// MARK: - Preview

#Preview {
    let history = ConversationHistory()
    let ws = ChatBackend.hermes.makeTransport(
        BackendConfig(endpoint: ChatBackend.hermes.defaultEndpoint, apiKey: "", model: ChatBackend.hermes.defaultModel)
    )
    let controller = ConversationController(
        chatTransport: ws,
        ttsService: MockTTSService(),
        audioPlayer: AudioPlayerService(),
        history: history
    )

    ChatView(
        conversationController: controller,
        conversationHistory: history
    )
    .frame(width: 360, height: 600)
    .preferredColorScheme(.dark)
}

// MARK: - Mock Services for Preview

private final class MockTTSService: TTSServiceProtocol, Sendable {
    let apiKey: String = ""
    let groupID: String = ""
    let voiceID: String = ""

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

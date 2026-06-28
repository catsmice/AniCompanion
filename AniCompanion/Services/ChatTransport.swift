import Foundation
import Combine

// MARK: - Transport Vocabulary
//
// The `WS` prefix on these types is historical — the original backend was a WebSocket
// gateway. They are transport-neutral now and shared by `HTTPChatService` and the
// conversation pipeline. (Renaming them is optional future tidy-up.)

/// Outgoing messages from the client to the chat backend.
enum WSOutgoing: Sendable {
    case chat(id: String, messages: [[String: String]])
    case cancel(ref: String)
    case ack(ref: String)
}

/// Incoming events from the chat backend to the client.
///
/// `welcome` / `notify` / `heartbeat` are not produced by `HTTPChatService` today;
/// `notify` is reserved for a future cron/proactive-push integration. They remain so the
/// pipeline's event switch stays exhaustive and a future transport can emit them.
enum WSIncoming: Sendable {
    case welcome(session: String)
    case token(ref: String, content: String, source: String)
    case done(ref: String, source: String)
    case error(ref: String?, message: String)
    case notify(ref: String, source: String)
    case heartbeat
}

/// Connection / reachability state of the transport.
enum WSConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}

/// Errors surfaced by a chat transport.
enum ChatTransportError: LocalizedError {
    case notConnected
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the chat backend."
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}

// MARK: - ChatTransport

/// Abstraction over the chat backend so the pipeline doesn't care which gateway or wire
/// protocol delivers the tokens. The built-in transports stream over HTTP/SSE (Hermes
/// Agent and any OpenAI-compatible server); a future transport could use something else.
///
/// Every transport speaks the same event vocabulary above, so `ConversationController`
/// consumes any of them unchanged.
@MainActor
protocol ChatTransport: AnyObject {

    /// Single stream of incoming events (tokens, completion, errors, notifications).
    var events: AsyncStream<WSIncoming> { get }

    /// Current connection/reachability state.
    var connectionState: WSConnectionState { get }

    /// Publisher for `connectionState`, used by observers that can't reach the
    /// concrete type's `@Published` projected value through the protocol.
    var connectionStatePublisher: AnyPublisher<WSConnectionState, Never> { get }

    /// Establish or verify the connection. For the HTTP/SSE transports this is a lightweight
    /// reachability probe rather than a persistent socket.
    func connect()

    /// Tear down the connection and stop any in-flight work.
    func disconnect()

    /// Send an outgoing message (chat request, cancel, or ack).
    func send(_ message: WSOutgoing) async throws
}

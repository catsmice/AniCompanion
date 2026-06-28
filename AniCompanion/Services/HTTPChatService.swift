import Foundation
import Combine

/// Chat transport for any **OpenAI-compatible** HTTP gateway
/// (`POST /v1/chat/completions`, `stream: true`). [Hermes Agent](https://github.com/NousResearch/hermes-agent)
/// is the reference backend, but the same code drives Ollama, LM Studio, vLLM, OpenRouter,
/// etc. — only `serviceName` (for error text) and `healthCheckPath` differ between them.
///
/// Unlike the legacy WebSocket gateway, this is request/response: each `.chat` send
/// opens its own streaming HTTP request, parses the Server-Sent Events, and yields the
/// same `WSIncoming` events the pipeline already understands:
/// - each `chat.completion.chunk` delta → `.token(ref:, content:, source: "chat")`
/// - the `data: [DONE]` sentinel (or stream end) → `.done(ref:, source: "chat")`
/// - non-200 / transport failure → `.error(ref:, message:)`
///
/// There is no persistent socket, heartbeat, or reconnect loop. `connect()` probes
/// `GET {healthCheckPath}` (Hermes: `/health`, requiring a 200) so the UI's connection
/// indicator is honest; gateways without a health route pass `healthCheckPath: nil`, and
/// `connect()` falls back to a lenient base-URL reachability check. Server-pushed
/// notifications (the legacy `notify` event) have no HTTP equivalent yet.
@MainActor
final class HTTPChatService: ObservableObject, ChatTransport {

    // MARK: - Published State

    @Published private(set) var connectionState: WSConnectionState = .disconnected

    var connectionStatePublisher: AnyPublisher<WSConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    // MARK: - Public Stream

    let events: AsyncStream<WSIncoming>
    private let eventsContinuation: AsyncStream<WSIncoming>.Continuation

    // MARK: - Configuration

    /// Base URL of the gateway, e.g. `http://127.0.0.1:8642` (no trailing slash). The
    /// transport appends `/v1/chat/completions` to it.
    private let baseURL: String
    /// Bearer token (for Hermes, its `API_SERVER_KEY`). Empty string = unauthenticated.
    private let apiKey: String
    /// Model name sent with each request. Some gateways pick the model server-side and ignore it.
    private let model: String
    /// Gateway name used in user-facing error messages ("Hermes", "OpenAI-compatible", …).
    private let serviceName: String
    /// Health-probe path (e.g. `/health`) requiring a 200, or `nil` for a lenient base-URL
    /// reachability check when the gateway has no health route.
    private let healthCheckPath: String?
    private let session: URLSession

    // MARK: - Private State

    /// In-flight streaming requests keyed by chat ref, so `.cancel` can stop one.
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var healthTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        endpoint: String,
        apiKey: String,
        model: String = "hermes-agent",
        serviceName: String = "Hermes",
        healthCheckPath: String? = "/health"
    ) {
        self.baseURL = Self.normalizeBaseURL(endpoint)
        self.apiKey = apiKey
        self.model = model
        self.serviceName = serviceName
        self.healthCheckPath = healthCheckPath

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        let (stream, continuation) = AsyncStream<WSIncoming>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    // MARK: - ChatTransport

    func connect() {
        guard connectionState != .connected else { return }
        connectionState = .connecting
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            await self?.checkHealth()
        }
    }

    func disconnect() {
        healthTask?.cancel()
        healthTask = nil
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        connectionState = .disconnected
    }

    func send(_ message: WSOutgoing) async throws {
        switch message {
        case .chat(let id, let messages):
            startChat(ref: id, messages: messages)
        case .cancel(let ref):
            activeTasks[ref]?.cancel()
            activeTasks[ref] = nil
        case .ack:
            // No server-push to acknowledge over HTTP. No-op.
            break
        }
    }

    // MARK: - Health

    private func checkHealth() async {
        // With a known health route (Hermes: /health) we require a 200. Gateways without
        // one probe the base URL and accept *any* HTTP answer as "reachable" — a server
        // that responds at all is up, even if the base path 404s.
        let lenient = (healthCheckPath == nil)
        guard let url = URL(string: baseURL + (healthCheckPath ?? "")) else {
            connectionState = .disconnected
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse, lenient || http.statusCode == 200 {
                connectionState = .connected
            } else {
                connectionState = .disconnected
            }
        } catch {
            if !Task.isCancelled { connectionState = .disconnected }
        }
    }

    // MARK: - Streaming Chat

    private func startChat(ref: String, messages: [[String: String]]) {
        // Replace any prior request reusing this ref.
        activeTasks[ref]?.cancel()
        let task = Task { [weak self] in
            await self?.streamChat(ref: ref, messages: messages)
            self?.activeTasks[ref] = nil
        }
        activeTasks[ref] = task
    }

    private func streamChat(ref: String, messages: [[String: String]]) async {
        guard let url = URL(string: baseURL + "/v1/chat/completions") else {
            eventsContinuation.yield(.error(ref: ref, message: "Invalid \(serviceName) endpoint URL: \(baseURL)"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            eventsContinuation.yield(.error(ref: ref, message: "Failed to encode chat request: \(error.localizedDescription)"))
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                connectionState = .disconnected
                eventsContinuation.yield(.error(ref: ref, message: "No HTTP response from \(serviceName)."))
                return
            }
            guard http.statusCode == 200 else {
                let message: String
                switch http.statusCode {
                case 401, 403:
                    message = "\(serviceName) rejected the API key (HTTP \(http.statusCode)). Check the API Key in Settings."
                default:
                    message = "\(serviceName) returned HTTP \(http.statusCode)."
                }
                eventsContinuation.yield(.error(ref: ref, message: message))
                return
            }

            // 200 + bytes flowing → the gateway is reachable.
            connectionState = .connected

            for try await line in bytes.lines {
                if Task.isCancelled { return }

                // SSE wire format is OpenAI-standard: `data: {json}` lines separated by
                // blank lines. (Hermes' docs mention `event:` lines, but the live server
                // emits plain `data:` lines.) Ignore everything that isn't a data line.
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty { continue }
                if payload == "[DONE]" {
                    eventsContinuation.yield(.done(ref: ref, source: "chat"))
                    return
                }
                if let content = Self.parseDeltaContent(payload) {
                    eventsContinuation.yield(.token(ref: ref, content: content, source: "chat"))
                }
            }

            // Stream ended without an explicit [DONE]; treat as complete.
            eventsContinuation.yield(.done(ref: ref, source: "chat"))

        } catch is CancellationError {
            // Cancelled via `.cancel(ref:)` — the controller drives its own teardown.
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            connectionState = .disconnected
            eventsContinuation.yield(.error(ref: ref, message: error.localizedDescription))
        }
    }

    // MARK: - Parsing

    /// Extracts `choices[0].delta.content` from a chunk JSON, or nil for role-only /
    /// finish chunks that carry no text.
    private static func parseDeltaContent(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }

    /// Trims a trailing slash so we can append `/v1/chat/completions` cleanly.
    private static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

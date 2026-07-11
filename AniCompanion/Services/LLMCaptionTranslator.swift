import Foundation

// MARK: - LLMCaptionTranslator

/// Translates caption segments through the configured agent backend's OpenAI-compatible
/// `POST /v1/chat/completions` (Hermes, Ollama, LM Studio, …) — non-streaming, one small call
/// per (coalesced) segment batch.
///
/// Why an LLM over Apple Translation: context. The translator keeps the last few
/// (source → translation) pairs and replays them as prior chat turns, so names, honorifics,
/// and running topics stay consistent across subtitle lines — the thing a stateless
/// sentence-by-sentence MT model can't do. The trade is latency (a fraction of a second to
/// seconds, depending on the backend/model) and cost when the backend is a paid cloud model;
/// the controller's coalescing worker keeps a slow backend from building a backlog.
///
/// `history` is mutated without a lock — safe because it's only ever used by the controller's
/// single serial translation worker (one `translate` call completes before the next begins).
@MainActor
final class LLMCaptionTranslator: CaptionTranslator {

    /// The connection is read **lazily per call** (not captured at init), so a backend endpoint/key
    /// change from Settings mid-session is picked up on the next translation without a restart.
    private let connection: @MainActor () -> (endpoint: String, apiKey: String, model: String)
    private let systemPrompt: String

    /// Recent (source, translation) pairs replayed as context for consistency.
    private var history: [(source: String, translation: String)] = []
    private let historyLimit = 4

    private let session: URLSession

    init(
        connection: @escaping @MainActor () -> (endpoint: String, apiKey: String, model: String),
        sourceName: String,
        targetName: String
    ) {
        self.connection = connection
        self.systemPrompt = """
        You are a professional subtitle translator. Translate each user message from \
        \(sourceName) to \(targetName). The lines are live subtitles from audio, so they may be \
        fragmentary — translate naturally and colloquially, as subtitles read. Keep names, \
        honorifics, and terminology consistent with earlier lines. Output ONLY the translation: \
        no quotes, no notes, no source text.
        """

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    func translate(_ text: String) async throws -> String {
        let (rawEndpoint, apiKey, model) = connection()
        // Match HTTPChatService's convention: base URL without a trailing slash, then append.
        var base = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw ChatTransportError.serverError("Invalid translator endpoint")
        }

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for pair in history {
            messages.append(["role": "user", "content": pair.source])
            messages.append(["role": "assistant", "content": pair.translation])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "temperature": 0.3,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ChatTransportError.serverError("Translator HTTP \(code)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatTransportError.serverError("Translator returned an unexpected response")
        }

        let translation = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            throw ChatTransportError.serverError("Translator returned empty text")
        }

        history.append((text, translation))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        return translation
    }
}

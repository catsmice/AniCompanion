import SwiftUI

// MARK: - BackendConfig

/// Connection settings handed to a backend when its transport is created.
///
/// Backend-neutral on purpose: every agent gateway needs *some* endpoint and (usually) a
/// key. A backend that needs more can read additional `@AppStorage` values in its
/// `makeTransport(_:)` case, but most fit these three fields.
struct BackendConfig: Sendable {
    /// Base URL of the agent gateway (no trailing slash needed).
    var endpoint: String
    /// Bearer token / API key, if the backend authenticates. Empty string = none.
    var apiKey: String
    /// Model name to request. Some gateways pick the model server-side and ignore this.
    var model: String
}

// MARK: - ChatBackend

/// The registry of supported agent backends — "bring your own agent."
///
/// AniCompanion is a *face* for an LLM agent: it renders a VRM character, speaks, listens,
/// and runs the streaming chat → sentence → TTS → lip-sync pipeline. The only thing a
/// backend has to do is turn a list of role/content messages into a stream of tokens. That
/// contract is the `ChatTransport` protocol; this enum is the place where each backend is
/// registered and constructed.
///
/// ## Adding a backend
///   1. Implement a `ChatTransport` (see `HTTPChatService` for the streaming-HTTP shape).
///   2. Add a `case` here and fill in `displayName`, `defaultEndpoint`, `defaultModel`,
///      `configHint`, and the `makeTransport(_:)` branch.
/// That's it — `AppState` selects whichever backend the user picked, and the rest of the
/// app (pipeline, character, UI) is unchanged. See CONTRIBUTING.md → "Adding an agent backend".
enum ChatBackend: String, CaseIterable, Identifiable, Sendable {

    /// [Hermes Agent](https://github.com/NousResearch/hermes-agent) — local OpenAI-compatible
    /// gateway. The reference backend, validated end-to-end.
    case hermes

    /// Any OpenAI-compatible gateway (Ollama, LM Studio, vLLM, OpenRouter, …). Worked example
    /// of a second backend — note how its `makeTransport` arm differs from Hermes' only in
    /// `serviceName` and opting out of the `/health` probe. Reuses `HTTPChatService` wholesale.
    case openAICompatible

    /// Claude Code CLI driven as a subprocess (`CLIChatService`). No API key — uses the user's
    /// logged-in Claude subscription. The "endpoint" field optionally overrides the binary path.
    case claudeCode

    /// Codex CLI as a subprocess. No API key — uses the user's ChatGPT account.
    case codex

    /// Gemini CLI as a subprocess. Usually needs a `GEMINI_API_KEY` (its free OAuth tier was
    /// retired) — supplied via the API Key field. The "endpoint" field optionally overrides the path.
    case gemini

    var id: String { rawValue }

    /// `@AppStorage` key for the user's selected backend.
    static let storageKey = "chat_backend"

    /// Human-readable name shown in the Settings picker.
    var displayName: String {
        switch self {
        case .hermes: return "Hermes Agent"
        case .openAICompatible: return "OpenAI-compatible"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Endpoint pre-filled when the user first selects this backend.
    var defaultEndpoint: String {
        switch self {
        case .hermes: return "http://127.0.0.1:8642"
        case .openAICompatible: return "http://127.0.0.1:1234"   // LM Studio default
        case .claudeCode: return ""   // not a URL — optional absolute path to the `claude` binary
        case .codex: return ""        // optional absolute path to the `codex` binary
        case .gemini: return ""       // optional absolute path to the `gemini` binary
        }
    }

    /// Model name sent with each request. Cosmetic for backends that choose server-side.
    var defaultModel: String {
        switch self {
        case .hermes: return "hermes-agent"
        case .openAICompatible: return "local-model"
        case .claudeCode: return "sonnet"
        case .codex: return ""             // let Codex pick a plan-supported default
        case .gemini: return "gemini-2.5-flash"
        }
    }

    /// One-line help shown beneath the connection fields. Localized via the String Catalog.
    var configHint: LocalizedStringKey {
        switch self {
        case .hermes:
            return "Local Hermes Agent gateway (run `hermes gateway`); key is its API_SERVER_KEY"
        case .openAICompatible:
            return "Any OpenAI-compatible gateway (Ollama, LM Studio, vLLM, OpenRouter). The app POSTs to /v1/chat/completions on your endpoint."
        case .claudeCode:
            return "Runs your installed Claude Code CLI — no API key, uses your Claude login. Leave Endpoint blank to auto-find `claude`, or set an absolute path to the binary."
        case .codex:
            return "Runs your installed Codex CLI — no API key, uses your ChatGPT login. Leave Endpoint blank to auto-find `codex`, or set an absolute path to the binary."
        case .gemini:
            return "Runs your installed Gemini CLI. Usually needs a GEMINI_API_KEY (from Google AI Studio) in the API Key field — its free login tier was retired. Leave Endpoint blank to auto-find `gemini`."
        }
    }

    /// Builds the live transport for this backend from the user's connection settings.
    @MainActor
    func makeTransport(_ config: BackendConfig) -> any ChatTransport {
        switch self {
        case .hermes:
            // Uses the defaults: serviceName "Hermes", healthCheckPath "/health".
            return HTTPChatService(
                endpoint: config.endpoint,
                apiKey: config.apiKey,
                model: config.model
            )
        case .openAICompatible:
            // Same transport, different labels — and no /health route, so probe leniently.
            return HTTPChatService(
                endpoint: config.endpoint,
                apiKey: config.apiKey,
                model: config.model,
                serviceName: "OpenAI-compatible",
                healthCheckPath: nil
            )
        case .claudeCode:
            // Subprocess transport — `config.endpoint` optionally overrides the binary path.
            return CLIChatService(
                spec: .claudeCode(model: config.model),
                model: config.model,
                executableOverride: config.endpoint
            )
        case .codex:
            return CLIChatService(
                spec: .codex(model: config.model),
                model: config.model,
                executableOverride: config.endpoint
            )
        case .gemini:
            return CLIChatService(
                spec: .gemini(model: config.model, apiKey: config.apiKey),
                model: config.model,
                executableOverride: config.endpoint
            )
        }
    }

    /// The currently selected backend (persisted choice, or the default).
    static var current: ChatBackend {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let backend = ChatBackend(rawValue: raw) {
            return backend
        }
        return .hermes
    }

    // MARK: - Per-Backend Connection Storage

    /// Each backend remembers its own endpoint + key, so switching the picker swaps the
    /// connection instead of clobbering it. Keys are namespaced by `rawValue`, e.g.
    /// `chat_endpoint_hermes`, `chat_api_key_openAICompatible`.
    var endpointStorageKey: String { "chat_endpoint_\(rawValue)" }
    var apiKeyStorageKey: String { "chat_api_key_\(rawValue)" }
    var modelStorageKey: String { "chat_model_\(rawValue)" }

    /// This backend's saved endpoint, falling back to `defaultEndpoint` when unset or blank.
    func savedEndpoint() -> String {
        let value = UserDefaults.standard.string(forKey: endpointStorageKey) ?? ""
        return value.isEmpty ? defaultEndpoint : value
    }

    /// This backend's saved API key (empty string = none).
    func savedAPIKey() -> String {
        UserDefaults.standard.string(forKey: apiKeyStorageKey) ?? ""
    }

    /// This backend's saved model, falling back to `defaultModel` when unset or blank. Lets a
    /// detected Ollama/LM Studio model (or a user override) persist per backend — `defaultModel`'s
    /// `"local-model"` placeholder would otherwise be rejected by Ollama.
    func savedModel() -> String {
        let value = UserDefaults.standard.string(forKey: modelStorageKey) ?? ""
        return value.isEmpty ? defaultModel : value
    }

    /// Persist this backend's connection settings. `model` is optional so existing callers that
    /// only set endpoint/key keep working; pass it to pin a specific model (e.g. from detection).
    func saveConnection(endpoint: String, apiKey: String, model: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(endpoint, forKey: endpointStorageKey)
        defaults.set(apiKey, forKey: apiKeyStorageKey)
        if let model { defaults.set(model, forKey: modelStorageKey) }
    }
}

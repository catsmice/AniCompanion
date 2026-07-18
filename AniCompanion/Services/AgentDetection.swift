import Foundation

// MARK: - DetectedAgent

/// One agent backend found on the user's machine, ready to present in the setup wizard.
///
/// `needsAPIKey == false` is the one-click tier (Hermes with an auto-filled key, or a logged-in
/// CLI). `endpoint`/`apiKey`/`model` are the values to persist onto `backend` when chosen.
struct DetectedAgent: Identifiable, Sendable {
    let id: String
    let backend: ChatBackend
    /// Display name, e.g. "Claude Code", "Ollama".
    let title: String
    /// One-line status, e.g. "no key · uses your Claude login", "3 models · llama3.2".
    let subtitle: String
    /// Whether the user must supply an API key before this can be used.
    let needsAPIKey: Bool
    /// Endpoint to persist (HTTP URL for gateways; empty for CLIs, which auto-resolve their binary).
    let endpoint: String
    /// API key to persist (auto-read for Hermes; empty otherwise).
    let apiKey: String
    /// Model to persist (enumerated for Ollama/LM Studio; empty = use the backend default).
    let model: String
}

// MARK: - AgentDetector

/// Probes the machine for usable agent backends: the coding-agent CLIs (Claude Code / Codex /
/// Gemini) by locating their binaries, and the local HTTP gateways (Hermes / Ollama / LM Studio)
/// by short-timeout requests. Hermes' key is auto-read from `~/.hermes/.env`. All probes run
/// concurrently; each is best-effort and never throws.
enum AgentDetector {

    /// Everything detected, ordered by tier: one-click no-key first, then local HTTP, then
    /// key-based.
    static func detectAll() async -> [DetectedAgent] {
        async let clis = detectCLIs()
        async let hermes = detectHermes()
        async let ollama = detectOllama()
        async let lmStudio = detectLMStudio()

        var found: [DetectedAgent] = await clis
        for optional in [await hermes, await ollama, await lmStudio] {
            if let agent = optional { found.append(agent) }
        }
        return found.sorted { rank($0.id) < rank($1.id) }
    }

    private static func rank(_ id: String) -> Int {
        switch id {
        case "hermes": return 0
        case "claudeCode": return 1
        case "codex": return 2
        case "ollama": return 3
        case "lmstudio": return 4
        case "gemini": return 5
        default: return 99
        }
    }

    // MARK: - CLIs

    private static func detectCLIs() async -> [DetectedAgent] {
        await withTaskGroup(of: DetectedAgent?.self) { group in
            for (backend, binary) in [
                (ChatBackend.claudeCode, "claude"),
                (ChatBackend.codex, "codex"),
                (ChatBackend.gemini, "gemini"),
            ] {
                group.addTask {
                    guard CLIChatService.locateExecutable(binary) != nil else { return nil }
                    switch backend {
                    case .claudeCode:
                        return DetectedAgent(
                            id: "claudeCode", backend: .claudeCode, title: "Claude Code",
                            subtitle: "no key · uses your Claude login",
                            needsAPIKey: false, endpoint: "", apiKey: "", model: ""
                        )
                    case .codex:
                        return DetectedAgent(
                            id: "codex", backend: .codex, title: "Codex",
                            subtitle: "no key · uses your ChatGPT login",
                            needsAPIKey: false, endpoint: "", apiKey: "", model: ""
                        )
                    case .gemini:
                        let hasKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.isEmpty == false
                        return DetectedAgent(
                            id: "gemini", backend: .gemini, title: "Gemini",
                            subtitle: hasKey ? "GEMINI_API_KEY found in environment"
                                             : "needs a GEMINI_API_KEY (free login tier retired)",
                            needsAPIKey: !hasKey, endpoint: "", apiKey: "", model: ""
                        )
                    default:
                        return nil
                    }
                }
            }
            var out: [DetectedAgent] = []
            for await agent in group where agent != nil { out.append(agent!) }
            return out
        }
    }

    // MARK: - Hermes

    private static func detectHermes() async -> DetectedAgent? {
        let endpoint = "http://127.0.0.1:8642"
        guard await httpGET("\(endpoint)/health") != nil else { return nil }
        let key = readHermesKey()
        return DetectedAgent(
            id: "hermes", backend: .hermes, title: "Hermes Agent",
            subtitle: key.isEmpty ? "running · enter its API key"
                                  : "running · key auto-filled from ~/.hermes/.env",
            needsAPIKey: key.isEmpty, endpoint: endpoint, apiKey: key, model: ""
        )
    }

    /// Read `API_SERVER_KEY` from `~/.hermes/.env` (a dotenv file). Returns "" if absent.
    static func readHermesKey() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/.env")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "API_SERVER_KEY" else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return ""
    }

    // MARK: - Ollama / LM Studio

    private static func detectOllama() async -> DetectedAgent? {
        let endpoint = "http://127.0.0.1:11434"
        guard let data = await httpGET("\(endpoint)/api/tags") else { return nil }
        let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0?["models"] as? [[String: Any]] }?
            .compactMap { $0["name"] as? String } ?? []
        return DetectedAgent(
            id: "ollama", backend: .openAICompatible, title: "Ollama",
            subtitle: models.isEmpty ? "running · no models pulled yet"
                                     : "\(models.count) model(s) · \(models[0])",
            needsAPIKey: false, endpoint: endpoint, apiKey: "", model: models.first ?? ""
        )
    }

    private static func detectLMStudio() async -> DetectedAgent? {
        let endpoint = "http://127.0.0.1:1234"
        guard let data = await httpGET("\(endpoint)/v1/models") else { return nil }
        let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0?["data"] as? [[String: Any]] }?
            .compactMap { $0["id"] as? String } ?? []
        return DetectedAgent(
            id: "lmstudio", backend: .openAICompatible, title: "LM Studio",
            subtitle: models.isEmpty ? "running" : "\(models.count) model(s) · \(models[0])",
            needsAPIKey: false, endpoint: endpoint, apiKey: "", model: models.first ?? ""
        )
    }

    // MARK: - HTTP helper

    /// Short-timeout GET returning the body on a 200, else nil. Never throws.
    private static func httpGET(_ urlString: String, timeout: TimeInterval = 1.5) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

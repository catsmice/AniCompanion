import Foundation
import Combine

// MARK: - CLIAgentSpec

/// Describes how to drive one coding-agent CLI (Claude Code, Codex, Gemini) as a chat backend.
///
/// The smoke tests showed the three CLIs share a shape — a headless flag, a streaming-JSON output
/// mode, and per-turn stdout events — but differ in their exact flags, trust guards, and JSON event
/// schema. This value captures those differences so one `CLIChatService` can run any of them.
struct CLIAgentSpec: Sendable {
    /// Stable id (matches the `ChatBackend` rawValue, e.g. "claudeCode").
    let id: String
    /// The executable name to resolve on PATH (e.g. "claude").
    let executableName: String
    /// Model passed with `--model`/`-m`. Empty = let the CLI pick its default.
    let defaultModel: String

    /// Build the argument list for one turn, given the flattened user prompt, the persona system
    /// prompt, and the model.
    let makeArguments: @Sendable (_ prompt: String, _ system: String, _ model: String) -> [String]

    /// Parse one line of stdout (a JSON object) into transport events. Returns `[]` for lines that
    /// carry no user-visible text (init/usage/etc.).
    let parseLine: @Sendable (_ line: String, _ ref: String) -> [WSIncoming]

    /// Extra environment variables to inject (e.g. `GEMINI_API_KEY`). Merged over the inherited env.
    let extraEnvironment: [String: String]
}

// MARK: - Claude Code spec

extension CLIAgentSpec {

    /// Claude Code: `claude -p <prompt> --output-format stream-json --verbose --system-prompt …`.
    /// Auth is the user's logged-in subscription (no API key). Streams `assistant` events with the
    /// reply text and a terminal `result` event.
    static func claudeCode(model: String) -> CLIAgentSpec {
        CLIAgentSpec(
            id: "claudeCode",
            executableName: "claude",
            defaultModel: model.isEmpty ? "sonnet" : model,
            makeArguments: { prompt, system, model in
                var args = [
                    "-p", prompt,
                    "--output-format", "stream-json",
                    "--verbose",                 // required for stream-json in -p mode
                    // Lean chat companion: no tools, no global MCP servers, no CLAUDE.md/skills/
                    // plugins. Cuts a casual turn from ~$0.17 to ~$0.01 and keeps her in-character.
                    "--tools", "",
                    "--strict-mcp-config",
                    "--setting-sources", "",
                ]
                if !system.isEmpty { args += ["--system-prompt", system] }
                if !model.isEmpty { args += ["--model", model] }
                return args
            },
            parseLine: { line, ref in
                guard let obj = CLIChatService.jsonObject(line),
                      let type = obj["type"] as? String else { return [] }
                switch type {
                case "assistant":
                    // { "message": { "content": [ { "type":"text", "text":"…" } ] } }
                    guard let message = obj["message"] as? [String: Any],
                          let content = message["content"] as? [[String: Any]] else { return [] }
                    return content.compactMap { part in
                        guard (part["type"] as? String) == "text",
                              let text = part["text"] as? String, !text.isEmpty else { return nil }
                        return .token(ref: ref, content: text, source: "chat")
                    }
                case "result":
                    // Terminal event. `is_error` marks a failed turn (e.g. usage limit).
                    if (obj["is_error"] as? Bool) == true {
                        let msg = (obj["result"] as? String) ?? "The agent CLI reported an error."
                        return [.error(ref: ref, message: msg)]
                    }
                    return [.done(ref: ref, source: "chat")]
                default:
                    return []
                }
            },
            extraEnvironment: [:]
        )
    }

    /// Codex CLI: `codex exec <prompt> --json --skip-git-repo-check -s read-only`. Auth is the
    /// user's ChatGPT account (no API key). Codex has no system-prompt flag, so the persona is
    /// prepended to the prompt. Streams `item.completed`/`agent_message` and a terminal
    /// `turn.completed`. Model is left to Codex's default — a ChatGPT plan rejects some names
    /// (e.g. `gpt-5-codex`), so only pass `-m` when the user sets one explicitly.
    static func codex(model: String) -> CLIAgentSpec {
        CLIAgentSpec(
            id: "codex",
            executableName: "codex",
            defaultModel: model,   // empty is fine — Codex picks a supported default
            makeArguments: { prompt, system, model in
                let combined = system.isEmpty ? prompt : "\(system)\n\n----- Conversation -----\n\n\(prompt)"
                var args = ["exec", combined, "--json", "--skip-git-repo-check", "-s", "read-only"]
                if !model.isEmpty { args += ["-m", model] }
                return args
            },
            parseLine: { line, ref in
                guard let obj = CLIChatService.jsonObject(line),
                      let type = obj["type"] as? String else { return [] }
                switch type {
                case "item.completed":
                    guard let item = obj["item"] as? [String: Any],
                          (item["type"] as? String) == "agent_message",
                          let text = item["text"] as? String, !text.isEmpty else { return [] }
                    return [.token(ref: ref, content: text, source: "chat")]
                case "turn.completed":
                    return [.done(ref: ref, source: "chat")]
                case "error":
                    return [.error(ref: ref, message: (obj["message"] as? String) ?? "Codex reported an error.")]
                case "turn.failed":
                    let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed."
                    return [.error(ref: ref, message: msg)]
                default:
                    return []
                }
            },
            extraEnvironment: [:]
        )
    }

    /// Gemini CLI: `gemini -p <prompt> -o stream-json --skip-trust`. Unlike Claude/Codex, its
    /// free-tier OAuth login was retired, so it usually needs a `GEMINI_API_KEY` (passed via env).
    /// No system-prompt flag, so the persona is prepended to the prompt.
    ///
    /// ⚠️ **Provisional parser:** Gemini's `stream-json` event schema is **unverified** — the
    /// account on the dev machine hits `IneligibleTierError`, so its output couldn't be smoke-tested.
    /// This extracts text from the most likely fields and relies on the process-exit fallback in
    /// `runProcess` to signal completion. Verify + tighten once a `GEMINI_API_KEY` is available.
    static func gemini(model: String, apiKey: String) -> CLIAgentSpec {
        CLIAgentSpec(
            id: "gemini",
            executableName: "gemini",
            defaultModel: model.isEmpty ? "gemini-2.5-flash" : model,
            makeArguments: { prompt, system, model in
                let combined = system.isEmpty ? prompt : "\(system)\n\n----- Conversation -----\n\n\(prompt)"
                var args = ["-p", combined, "-o", "stream-json", "--skip-trust"]
                if !model.isEmpty { args += ["-m", model] }
                return args
            },
            parseLine: { line, ref in
                guard let obj = CLIChatService.jsonObject(line) else { return [] }
                // Best-effort text extraction across a few plausible shapes; done is inferred at
                // process exit. Replace with the real schema after a smoke test.
                if let text = (obj["text"] as? String) ?? (obj["content"] as? String)
                    ?? (obj["response"] as? String), !text.isEmpty {
                    return [.token(ref: ref, content: text, source: "chat")]
                }
                if let delta = obj["delta"] as? [String: Any],
                   let text = delta["text"] as? String, !text.isEmpty {
                    return [.token(ref: ref, content: text, source: "chat")]
                }
                return []
            },
            extraEnvironment: apiKey.isEmpty ? [:] : ["GEMINI_API_KEY": apiKey]
        )
    }
}

// MARK: - CLIChatService

/// A `ChatTransport` that drives a coding-agent CLI as a subprocess. Each `.chat` send spawns the
/// CLI once (in a clean working directory, with the persona installed via the CLI's system-prompt
/// flag), streams its stdout JSON into the same `WSIncoming` events the pipeline already understands,
/// and terminates the process on `.cancel`.
///
/// Auth is the CLI's own logged-in session, so most of these backends need **no API key** — the
/// headline reason they exist. Runs the CLI in a dedicated empty directory so it can't pick up a
/// project's `CLAUDE.md`/`AGENTS.md` (which otherwise balloons context + cost).
@MainActor
final class CLIChatService: ObservableObject, ChatTransport {

    // MARK: - Published State

    @Published private(set) var connectionState: WSConnectionState = .disconnected

    var connectionStatePublisher: AnyPublisher<WSConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    // MARK: - Public Stream

    let events: AsyncStream<WSIncoming>
    private let eventsContinuation: AsyncStream<WSIncoming>.Continuation

    // MARK: - Configuration

    private let spec: CLIAgentSpec
    private let model: String
    /// Absolute path to the CLI binary, or nil if it couldn't be found on this machine.
    private let executableURL: URL?
    /// A dedicated empty directory the CLI runs in, so it inherits no project context.
    private let workingDirectory: URL

    // MARK: - Private State

    /// In-flight turns keyed by chat ref, so `.cancel` can terminate one.
    private var activeProcesses: [String: Process] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Initialization

    init(spec: CLIAgentSpec, model: String, executableOverride: String = "") {
        self.spec = spec
        self.model = model.isEmpty ? spec.defaultModel : model
        self.executableURL = Self.resolveExecutable(name: spec.executableName, override: executableOverride)
        self.workingDirectory = Self.makeWorkingDirectory()

        let (stream, continuation) = AsyncStream<WSIncoming>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    // MARK: - ChatTransport

    func connect() {
        // A CLI backend is "reachable" if we could find its binary. Whether the user is actually
        // logged in is only knowable by running it — that's the wizard's live test-run.
        connectionState = (executableURL != nil) ? .connected : .disconnected
    }

    func disconnect() {
        for (_, task) in activeTasks { task.cancel() }
        for (_, process) in activeProcesses where process.isRunning { process.terminate() }
        activeTasks.removeAll()
        activeProcesses.removeAll()
        connectionState = .disconnected
    }

    func send(_ message: WSOutgoing) async throws {
        switch message {
        case .chat(let id, let messages, _):
            // Images (screen vision) aren't wired for CLI backends yet — text path only.
            startChat(ref: id, messages: messages)
        case .cancel(let ref):
            activeTasks[ref]?.cancel()
            activeProcesses[ref]?.terminate()
            activeTasks[ref] = nil
            activeProcesses[ref] = nil
        case .ack:
            break
        }
    }

    // MARK: - Turn

    private func startChat(ref: String, messages: [[String: String]]) {
        guard let executableURL else {
            eventsContinuation.yield(.error(
                ref: ref,
                message: "\(spec.executableName) isn't installed (or wasn't found on PATH)."
            ))
            return
        }

        // Split the transcript: system messages install the persona; the rest become a flattened
        // conversational prompt ending on the latest user turn.
        let system = messages
            .filter { $0["role"] == "system" }
            .compactMap { $0["content"] }
            .joined(separator: "\n\n")
        let prompt = messages
            .filter { $0["role"] != "system" }
            .map { "\(($0["role"] ?? "user").capitalized): \($0["content"] ?? "")" }
            .joined(separator: "\n\n")

        let arguments = spec.makeArguments(prompt, system, model)
        let cwd = workingDirectory
        let parseLine = spec.parseLine
        let extraEnv = spec.extraEnvironment
        let continuation = eventsContinuation

        activeProcesses[ref]?.terminate()

        let task = Task { [weak self] in
            await Self.runProcess(
                ref: ref,
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: cwd,
                extraEnvironment: extraEnv,
                parseLine: parseLine,
                continuation: continuation,
                register: { process in self?.activeProcesses[ref] = process }
            )
            self?.activeProcesses[ref] = nil
            self?.activeTasks[ref] = nil
        }
        activeTasks[ref] = task
    }

    /// Spawn the CLI, stream stdout lines through `parseLine`, and surface a terminal error if it
    /// exits non-zero without having produced a `done`. Runs off the main actor (process I/O).
    private nonisolated static func runProcess(
        ref: String,
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        extraEnvironment: [String: String],
        parseLine: @Sendable (String, String) -> [WSIncoming],
        continuation: AsyncStream<WSIncoming>.Continuation,
        register: @MainActor @Sendable (Process) -> Void
    ) async {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice   // don't block waiting on stdin (codex)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            continuation.yield(.error(ref: ref, message: "Couldn't launch \(executableURL.lastPathComponent): \(error.localizedDescription)"))
            return
        }
        await register(process)

        var sawDone = false
        var sawText = false
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                for event in parseLine(trimmed, ref) {
                    switch event {
                    case .token: sawText = true
                    case .done: sawDone = true
                    default: break
                    }
                    continuation.yield(event)
                }
            }
        } catch {
            if !Task.isCancelled {
                continuation.yield(.error(ref: ref, message: error.localizedDescription))
            }
        }

        process.waitUntilExit()

        if Task.isCancelled { return }

        // Exited non-zero without a clean completion → surface stderr (auth failures land here).
        if process.terminationStatus != 0 && !sawDone {
            let errText = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (errText?.isEmpty == false)
                ? errText!
                : "\(executableURL.lastPathComponent) exited with status \(process.terminationStatus)."
            continuation.yield(.error(ref: ref, message: message))
        } else if !sawDone && sawText {
            // Produced text but never a terminal event — treat stream end as completion.
            continuation.yield(.done(ref: ref, source: "chat"))
        }
    }

    // MARK: - Helpers

    /// Parse one NDJSON line into a dictionary, or nil if it isn't a JSON object.
    nonisolated static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Locate a CLI binary by name (no override) — used by agent detection.
    nonisolated static func locateExecutable(_ name: String) -> URL? {
        resolveExecutable(name: name, override: "")
    }

    /// Locate the CLI binary. A Finder-launched app has a minimal PATH, so probe the common
    /// install locations first, then fall back to a login-shell `which`.
    nonisolated private static func resolveExecutable(name: String, override: String) -> URL? {
        let fm = FileManager.default
        let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverride.isEmpty, fm.isExecutableFile(atPath: trimmedOverride) {
            return URL(fileURLWithPath: trimmedOverride)
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        ]
        for dir in candidates {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return loginShellWhich(name)
    }

    /// Resolve a binary via the user's login shell (picks up their real PATH: nvm, asdf, etc.).
    nonisolated private static func loginShellWhich(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A dedicated empty directory under Application Support so the CLI inherits no project context.
    private static func makeWorkingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AniCompanion/AgentWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

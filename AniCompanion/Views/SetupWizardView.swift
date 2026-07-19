import SwiftUI

// MARK: - SetupWizardView

/// First-run agent setup. Detects usable backends on the machine (logged-in CLIs, a running Hermes
/// with its key auto-read, Ollama/LM Studio), lets the user pick one (or enter a cloud API key),
/// runs a **live test** so "installed but not logged in" fails here instead of in chat, then saves.
///
/// Presented as a sheet driven by `AppState.showSetupWizard` — on first launch, or from the
/// Settings "Re-run setup" button.
struct SetupWizardView: View {

    @EnvironmentObject private var appState: AppState

    private enum Phase: Equatable {
        case detecting, choose, configure, testing, done
    }

    @State private var phase: Phase = .detecting
    @State private var detected: [DetectedAgent] = []

    /// The chosen detected agent (nil when entering a cloud connection manually).
    @State private var selected: DetectedAgent?
    @State private var isCloud = false

    // Editable connection fields for the `configure` phase.
    @State private var fieldEndpoint = ""
    @State private var fieldKey = ""
    @State private var fieldModel = ""

    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(nsColor: NSColor(red: 0.15, green: 0.12, blue: 0.22, alpha: 1.0)),
                    Color(nsColor: NSColor(red: 0.07, green: 0.07, blue: 0.11, alpha: 1.0)),
                ]),
                center: .top, startRadius: 40, endRadius: 520
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
        .frame(width: 470, height: 520)
        .overlay(alignment: .topTrailing) { closeButton }
        .preferredColorScheme(.dark)
        .task { if phase == .detecting { await runDetection() } }
    }

    /// Always-visible dismiss button, shown on every phase (the per-phase buttons don't cover
    /// detecting/testing). Treats close like "Skip" — marks setup handled so first-run doesn't
    /// nag on the next launch; the Settings "Re-run setup…" button and the "No AI model connected"
    /// banner remain as ways back in.
    private var closeButton: some View {
        Button { skip() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Close")
        .padding(14)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Let's connect Xiaoguang to a model")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content by phase

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .detecting: detectingView
        case .choose:    chooseView
        case .configure: configureView
        case .testing:   testingView
        case .done:      doneView
        }
    }

    private var detectingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            Text("Looking for AI models on your Mac…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage {
                    banner(errorMessage, isError: true)
                }

                if !detected.isEmpty {
                    Text("Found on your Mac")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    VStack(spacing: 8) {
                        ForEach(detected) { agent in
                            agentCard(agent)
                        }
                    }
                } else {
                    banner(String(localized: "No local AI model was found. Connect a cloud service below, or install Claude Code / Ollama and rescan."), isError: false)
                }

                Text("Or connect manually")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
                actionCard(icon: "cloud", title: "Connect a cloud model / API key…",
                           subtitle: "OpenAI, OpenRouter, Groq, or any OpenAI-compatible endpoint") {
                    chooseCloud()
                }

                HStack {
                    Button("Rescan") { Task { await runDetection() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button("Skip for now") { skip() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(size: 12))
                .padding(.top, 6)
            }
        }
    }

    private var configureView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selected?.title ?? String(localized: "Cloud model"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            if let errorMessage {
                banner(errorMessage, isError: true)
            }

            if isCloud {
                field("Endpoint", text: $fieldEndpoint, placeholder: "https://api.openai.com")
            }
            field("API Key", text: $fieldKey, placeholder: "sk-…", secure: true)
            if isCloud || selected?.backend == .gemini {
                field("Model", text: $fieldModel, placeholder: isCloud ? "gpt-4o-mini" : "gemini-2.5-flash")
            }

            Spacer()

            HStack {
                Button("Back") { phase = .choose; errorMessage = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Test & Use") { Task { await test() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(fieldKey.isEmpty && isCloud)
            }
            .font(.system(size: 13))
        }
    }

    private var testingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            Text("Testing the connection…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Text("A CLI backend may take a few seconds to start.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Xiaoguang is ready")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("You can change this anytime in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button("Start chatting") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cards & fields

    private func agentCard(_ agent: DetectedAgent) -> some View {
        // A ternary of two string literals resolves to `String` (non-localizing); pin the type to
        // LocalizedStringKey so both call-to-action labels go through the String Catalog.
        let cta: LocalizedStringKey = agent.needsAPIKey ? "Set up →" : "Use →"
        return Button { choose(agent) } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(agent.needsAPIKey ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Text(agent.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(cta)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.purple.opacity(0.9))
            }
            .padding(12)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    private func actionCard(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(12)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private func banner(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? .orange : .white.opacity(0.5))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(isError ? Color.orange.opacity(0.12) : Color.white.opacity(0.05)))
    }

    // MARK: - Logic

    private func runDetection() async {
        phase = .detecting
        errorMessage = nil
        detected = await AgentDetector.detectAll()
        phase = .choose
    }

    private func choose(_ agent: DetectedAgent) {
        selected = agent
        isCloud = false
        fieldEndpoint = agent.endpoint
        fieldKey = agent.apiKey
        fieldModel = agent.model
        errorMessage = nil
        if agent.needsAPIKey {
            phase = .configure
        } else {
            Task { await test() }
        }
    }

    private func chooseCloud() {
        selected = nil
        isCloud = true
        fieldEndpoint = ""
        fieldKey = ""
        fieldModel = ""
        errorMessage = nil
        phase = .configure
    }

    /// The (backend, endpoint, key, model) currently chosen — from the selected agent, overlaid
    /// with any edited fields.
    private func resolvedConnection() -> (backend: ChatBackend, endpoint: String, key: String, model: String) {
        let backend = isCloud ? .openAICompatible : (selected?.backend ?? .openAICompatible)
        let endpoint = isCloud ? fieldEndpoint : (selected?.endpoint ?? "")
        let key = fieldKey.isEmpty ? (selected?.apiKey ?? "") : fieldKey
        let model = fieldModel.isEmpty ? (selected?.model ?? "") : fieldModel
        return (backend, endpoint, key, model)
    }

    private func test() async {
        phase = .testing
        errorMessage = nil
        let conn = resolvedConnection()
        let config = BackendConfig(
            endpoint: conn.endpoint,
            apiKey: conn.key,
            model: conn.model.isEmpty ? conn.backend.defaultModel : conn.model
        )
        let outcome = await AgentDetector.test(backend: conn.backend, config: config)
        switch outcome {
        case .success:
            appState.applyAgentSelection(backend: conn.backend, endpoint: conn.endpoint, apiKey: conn.key, model: conn.model)
            phase = .done
        case .failure(let message):
            errorMessage = message
            // Return to where they can fix it: the config form if it takes input, else the list.
            phase = (isCloud || (selected?.needsAPIKey ?? false)) ? .configure : .choose
        }
    }

    private func skip() {
        appState.agentSetupCompleted = true
        dismiss()
    }

    private func dismiss() {
        appState.showSetupWizard = false
    }
}

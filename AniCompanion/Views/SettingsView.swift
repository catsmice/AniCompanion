import SwiftUI

// MARK: - SettingsView

/// A form-based settings panel presented as a sheet.
///
/// Allows the user to configure the agent backend connection, API keys, TTS voice,
/// and interface/character language. Settings are persisted via `AppState`'s
/// `@AppStorage` properties.
struct SettingsView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewAudioPlayer = AudioPlayerService()

    // Local copies for edit-then-save workflow.
    @State private var minimaxAPIKey: String = ""
    @State private var minimaxGroupID: String = ""
    @State private var backend: ChatBackend = .hermes
    /// Per-backend working copies (edit-then-save). Switching the picker swaps which
    /// backend's entry the fields show; nothing is persisted until Save.
    @State private var endpoints: [ChatBackend: String] = [:]
    @State private var apiKeys: [ChatBackend: String] = [:]
    @State private var ttsProvider: TTSProvider = .miniMax
    @State private var blueMagpieTTSEndpoint: String = "http://127.0.0.1:8765"
    @State private var blueMagpieInferenceTimesteps: Int = 5
    @State private var openAITTSAPIKey: String = ""
    @State private var openAITTSModel: String = OpenAITTSService.defaultModel
    @State private var openAITTSVoice: String = OpenAITTSService.defaultVoice
    @State private var openAITTSInstructions: String = OpenAITTSService.defaultInstructions
    @State private var openAITTSSpeed: Double = 1.0
    @State private var ttsVoiceID: String = "Chinese (Mandarin)_Crisp_Girl"
    @State private var ttsEnabled: Bool = true
    @State private var language: AppLanguage = .english
    @State private var vrmModelFilename: String = "AliciaSolid.vrm"

    /// Shows the "restart to apply UI language" alert after a language change.
    @State private var showRestartAlert = false
    @State private var isTestingVoice = false
    @State private var voicePreviewError: String?
    @State private var voicePreviewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header

            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // MARK: - Form Content

            ScrollView {
                VStack(spacing: 24) {

                    // MARK: Section 0: Connection

                    SettingsSection(title: "Connection", icon: "network") {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsField(label: "Agent backend") {
                                Picker("", selection: $backend) {
                                    ForEach(ChatBackend.allCases) { b in
                                        Text(b.displayName).tag(b)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                // No onChange needed: the fields bind to the selected backend's
                                // working copy, so switching the picker swaps them automatically.
                            }

                            SettingsField(label: "Endpoint") {
                                TextField(backend.defaultEndpoint, text: endpointBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }

                            SettingsField(label: "API Key") {
                                SecureField("API key (if required)", text: apiKeyBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            Text(backend.configHint)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    // MARK: Section 1: Character

                    SettingsSection(title: "Character", icon: "person.crop.square") {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsField(label: "VRM Model Filename") {
                                TextField("AliciaSolid.vrm", text: $vrmModelFilename)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }

                            Text("File must exist in Resources/VRMModel.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    // MARK: Section 2: Voice

                    SettingsSection(title: "Voice", icon: "speaker.wave.2.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Enable TTS Voice", isOn: $ttsEnabled)
                                .toggleStyle(.switch)

                            SettingsField(label: "TTS Provider") {
                                Picker("", selection: $ttsProvider) {
                                    ForEach(TTSProvider.allCases) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }

                            switch ttsProvider {
                            case .miniMax:
                                SettingsField(label: "MiniMax API Key") {
                                    SecureField("eyJ...", text: $minimaxAPIKey)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }

                                SettingsField(label: "MiniMax Group ID") {
                                    TextField("Group ID", text: $minimaxGroupID)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }

                                SettingsField(label: "TTS Voice ID") {
                                    TextField("Voice ID", text: $ttsVoiceID)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }
                            case .blueMagpie:
                                SettingsField(label: "BlueMagpie Server") {
                                    TextField("http://127.0.0.1:8765", text: $blueMagpieTTSEndpoint)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }

                                SettingsField(label: "Inference Timesteps") {
                                    Stepper(value: $blueMagpieInferenceTimesteps, in: 1...12) {
                                        Text("\(blueMagpieInferenceTimesteps)")
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundStyle(.white)
                                    }
                                }
                            case .openAI:
                                SettingsField(label: "OpenAI API Key") {
                                    SecureField("sk-...", text: $openAITTSAPIKey)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }

                                SettingsField(label: "OpenAI TTS Model") {
                                    Picker("", selection: $openAITTSModel) {
                                        ForEach(OpenAITTSService.modelOptions, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }

                                SettingsField(label: "OpenAI Voice") {
                                    Picker("", selection: $openAITTSVoice) {
                                        ForEach(OpenAITTSService.voiceOptions(for: openAITTSModel), id: \.id) { voice in
                                            Text(voice.menuLabel(language: language)).tag(voice.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .onChange(of: openAITTSModel) { _, newModel in
                                        let voices = OpenAITTSService.voiceOptions(for: newModel)
                                        if !voices.contains(where: { $0.id == openAITTSVoice }) {
                                            openAITTSVoice = voices.first?.id ?? OpenAITTSService.defaultVoice
                                        }
                                    }
                                }

                                let voiceDetail = OpenAITTSService.voiceDetail(
                                    for: openAITTSVoice,
                                    model: openAITTSModel,
                                    language: language
                                )
                                if !voiceDetail.isEmpty {
                                    Text(voiceDetail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                }

                                SettingsField(label: "Voice Instructions") {
                                    TextField(
                                        "Speak naturally, warm and expressive.",
                                        text: $openAITTSInstructions,
                                        axis: .vertical
                                    )
                                    .lineLimit(2...4)
                                    .textFieldStyle(.plain)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                }

                                SettingsField(label: "Speed") {
                                    HStack(spacing: 12) {
                                        Slider(value: $openAITTSSpeed, in: 0.25...4.0, step: 0.05)
                                        Text("\(openAITTSSpeed, specifier: "%.2f")x")
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundStyle(.white)
                                            .frame(width: 48, alignment: .trailing)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    previewVoice()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isTestingVoice {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "play.circle.fill")
                                        }
                                        if isTestingVoice {
                                            Text("Testing Voice...")
                                        } else {
                                            Text("Test Voice")
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isTestingVoice)

                                if let voicePreviewError {
                                    Text(voicePreviewError)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    // MARK: Section 3: Language

                    SettingsSection(title: "Language", icon: "globe") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $language) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()

                            Text("Interface & character language. The interface updates after an app restart; the character switches right away.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Divider()

            // MARK: - Action Buttons

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button("Save") {
                    let languageChanged = (language != AppLanguage.current)
                    saveSettings()
                    if languageChanged {
                        showRestartAlert = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 640)
        .background(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)))
        .preferredColorScheme(.dark)
        .onAppear {
            loadSettings()
        }
        .onDisappear {
            cancelVoicePreview()
        }
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Restart AniCompanion to apply the new interface language. (The character switches right away.)")
        }
    }

    // MARK: - Per-Backend Connection Bindings

    /// The endpoint field, bound to the selected backend's working copy.
    private var endpointBinding: Binding<String> {
        Binding(
            get: { endpoints[backend] ?? backend.defaultEndpoint },
            set: { endpoints[backend] = $0 }
        )
    }

    /// The API-key field, bound to the selected backend's working copy.
    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { apiKeys[backend] ?? "" },
            set: { apiKeys[backend] = $0 }
        )
    }

    // MARK: - Voice Preview

    @MainActor
    private func previewVoice() {
        cancelVoicePreview()
        isTestingVoice = true
        voicePreviewError = nil

        let service = makePreviewTTSService()
        let text = previewText

        voicePreviewTask = Task {
            defer {
                isTestingVoice = false
                voicePreviewTask = nil
            }

            do {
                var audioData = Data()
                for try await chunk in service.synthesize(text: text, emotion: .happy) {
                    try Task.checkCancellation()
                    audioData.append(chunk)
                }
                guard !audioData.isEmpty else {
                    throw TTSError.decodingError("TTS preview returned empty audio.")
                }
                try Task.checkCancellation()
                try await previewAudioPlayer.playAudioData(audioData)
            } catch is CancellationError {
                previewAudioPlayer.stop()
            } catch {
                let format = String(localized: "Unable to preview voice: %@")
                voicePreviewError = String(format: format, error.localizedDescription)
            }
        }
    }

    @MainActor
    private func cancelVoicePreview() {
        voicePreviewTask?.cancel()
        voicePreviewTask = nil
        previewAudioPlayer.stop()
        isTestingVoice = false
    }

    private var previewText: String {
        String(localized: "Hi, I'm Xiaoguang. This is a voice preview.")
    }

    private func makePreviewTTSService() -> any TTSServiceProtocol {
        switch ttsProvider {
        case .miniMax:
            return TTSService(
                apiKey: minimaxAPIKey,
                groupId: minimaxGroupID,
                voiceId: ttsVoiceID
            )
        case .blueMagpie:
            return BlueMagpieTTSService(
                endpoint: blueMagpieTTSEndpoint,
                inferenceTimesteps: blueMagpieInferenceTimesteps
            )
        case .openAI:
            return OpenAITTSService(
                apiKey: openAITTSAPIKey,
                model: openAITTSModel,
                voice: openAITTSVoice,
                instructions: openAITTSInstructions,
                speed: openAITTSSpeed
            )
        }
    }

    // MARK: - Data Flow

    /// Load current settings from AppState into local state.
    private func loadSettings() {
        backend = ChatBackend.current
        // Seed every backend's working copy from its own saved connection.
        for b in ChatBackend.allCases {
            endpoints[b] = b.savedEndpoint()
            apiKeys[b] = b.savedAPIKey()
        }
        minimaxAPIKey = appState.minimaxAPIKey
        minimaxGroupID = appState.minimaxGroupID
        ttsProvider = TTSProvider(rawValue: appState.ttsProvider) ?? .miniMax
        blueMagpieTTSEndpoint = appState.blueMagpieTTSEndpoint
        blueMagpieInferenceTimesteps = appState.blueMagpieInferenceTimesteps
        openAITTSAPIKey = appState.openAITTSAPIKey
        openAITTSModel = appState.openAITTSModel
        openAITTSVoice = appState.openAITTSVoice
        openAITTSInstructions = appState.openAITTSInstructions
        openAITTSSpeed = appState.openAITTSSpeed
        ttsVoiceID = appState.ttsVoiceID
        ttsEnabled = appState.ttsEnabled
        language = AppLanguage.current
        vrmModelFilename = appState.vrmModelFilename
    }

    /// Write local state back to AppState for persistence, then reinitialize services.
    private func saveSettings() {
        appState.chatBackend = backend.rawValue
        // Persist each backend's own connection.
        for b in ChatBackend.allCases {
            b.saveConnection(
                endpoint: endpoints[b] ?? b.defaultEndpoint,
                apiKey: apiKeys[b] ?? ""
            )
        }
        appState.minimaxAPIKey = minimaxAPIKey
        appState.minimaxGroupID = minimaxGroupID
        appState.ttsProvider = ttsProvider.rawValue
        appState.blueMagpieTTSEndpoint = blueMagpieTTSEndpoint
        appState.blueMagpieInferenceTimesteps = blueMagpieInferenceTimesteps
        appState.openAITTSAPIKey = openAITTSAPIKey
        appState.openAITTSModel = openAITTSModel
        appState.openAITTSVoice = openAITTSVoice
        appState.openAITTSInstructions = openAITTSInstructions
        appState.openAITTSSpeed = openAITTSSpeed
        appState.ttsVoiceID = ttsVoiceID
        appState.ttsEnabled = ttsEnabled
        appState.vrmModelFilename = vrmModelFilename

        // Persist the language. The character/persona + STT pick it up immediately on
        // reinitialize; the SwiftUI interface needs `AppleLanguages` + a relaunch.
        appState.appLanguage = language.rawValue
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")

        // Apply TTS toggle immediately (no reinit needed).
        appState.conversationController?.ttsEnabled = ttsEnabled

        // Recreate services with updated settings.
        appState.reinitializeServices()
    }
}

// MARK: - SettingsSection

/// A labeled section container with an icon and title.
private struct SettingsSection<Content: View>: View {

    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // Section content
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsField

/// A labeled field within a settings section.
private struct SettingsField<Content: View>: View {

    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            content
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

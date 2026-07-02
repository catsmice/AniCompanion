import SwiftUI
import Combine
import WebKit

// MARK: - AppState

/// Central observable state object for AniCompanion.
///
/// Owns the app's settings (persisted via @AppStorage), the character manager,
/// conversation history, and the conversation controller that orchestrates the
/// full chat -> TTS -> playback pipeline. All UI reads from this single source
/// of truth via @EnvironmentObject.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Persisted Settings

    /// MiniMax API key for TTS synthesis.
    @AppStorage("minimax_api_key") var minimaxAPIKey: String = ""

    /// MiniMax group ID required by the T2A v2 endpoint.
    @AppStorage("minimax_group_id") var minimaxGroupID: String = ""

    /// Which TTS provider to use when voice output is enabled.
    @AppStorage(TTSProvider.storageKey) var ttsProvider: String = TTSProvider.miniMax.rawValue

    /// Base URL for a local BlueMagpie-TTS HTTP server.
    @AppStorage("bluemagpie_tts_endpoint") var blueMagpieTTSEndpoint: String = "http://127.0.0.1:8765"

    /// BlueMagpie diffusion sampling steps. Lower is faster, higher is usually better quality.
    @AppStorage("bluemagpie_inference_timesteps") var blueMagpieInferenceTimesteps: Int = 5

    /// OpenAI API key for the `/v1/audio/speech` TTS provider.
    @AppStorage("openai_tts_api_key") var openAITTSAPIKey: String = ""

    /// OpenAI speech model.
    @AppStorage("openai_tts_model") var openAITTSModel: String = OpenAITTSService.defaultModel

    /// OpenAI built-in voice name.
    @AppStorage("openai_tts_voice") var openAITTSVoice: String = OpenAITTSService.defaultVoice

    /// OpenAI voice instructions used by models that support promptable TTS.
    @AppStorage("openai_tts_instructions") var openAITTSInstructions: String = OpenAITTSService.defaultInstructions

    /// OpenAI speech speed multiplier.
    @AppStorage("openai_tts_speed") var openAITTSSpeed: Double = 1.0

    /// Which agent backend to talk to. See `ChatBackend`. Each backend stores its own
    /// endpoint + key under per-backend keys (see `ChatBackend.savedEndpoint()` /
    /// `savedAPIKey()`), so switching backends swaps the connection rather than sharing it.
    @AppStorage(ChatBackend.storageKey) var chatBackend: String = ChatBackend.hermes.rawValue

    /// The TTS voice ID used for speech synthesis.
    @AppStorage("tts_voice_id") var ttsVoiceID: String = "Chinese (Mandarin)_Crisp_Girl"

    /// Whether TTS voice output is enabled. When disabled, 小光 responds with text only.
    @AppStorage("tts_enabled") var ttsEnabled: Bool = true

    /// The app/character language (UI, persona, and speech recognition). See `AppLanguage`.
    @AppStorage("app_language") var appLanguage: String = AppLanguage.systemDefault.rawValue

    /// VRM model filename under Resources/VRMModel.
    @AppStorage("vrm_model_filename") var vrmModelFilename: String = "AliciaSolid.vrm"

    private var effectiveVRMModelFilename: String {
        let filename = vrmModelFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? "AliciaSolid.vrm" : filename
    }

    // MARK: - Owned Objects

    /// Manages the VRM character model via three-vrm in a WKWebView.
    @Published var characterManager: ThreeVRMCharacterManager

    /// In-memory conversation history with context windowing for LLM calls.
    @Published var conversationHistory: ConversationHistory

    /// The main pipeline orchestrator wiring the chat transport, TTS, STT, audio, and character animation.
    /// `nil` until `initializeServices()` runs; readers use optional access (`if let` / `?.`).
    @Published var conversationController: ConversationController?

    /// The active chat transport (Hermes Agent's OpenAI-compatible HTTP API).
    @Published var chatTransport: (any ChatTransport)?

    /// Whether the chat backend is currently connected/reachable.
    @Published var isConnected: Bool = false

    /// Desktop pet mode: the window becomes a borderless, transparent, always-on-top,
    /// draggable character with no chat panel. Toggled from the Character menu (⌘⇧D).
    @Published var petMode: Bool = false

    // MARK: - Private State

    /// Tracks whether services have been initialized to avoid double initialization.
    private var servicesInitialized = false

    /// Subscription for observing the chat transport's connection state.
    private var connectionCancellable: AnyCancellable?

    // MARK: - Initialization

    init() {
        self.characterManager = ThreeVRMCharacterManager()
        self.conversationHistory = ConversationHistory()
        Self.migrateLegacyConnectionDefaults()
    }

    /// One-time migration: earlier builds stored a single connection — first under
    /// Hermes-specific keys (`hermes_endpoint` / `hermes_api_key`), then under backend-neutral
    /// keys (`chat_endpoint` / `chat_api_key`). Both predate per-backend storage, and that
    /// single connection was always the Hermes one, so fold it into Hermes' per-backend keys.
    /// Safe to keep indefinitely; it no-ops once the per-backend keys exist.
    private static func migrateLegacyConnectionDefaults() {
        let defaults = UserDefaults.standard
        let hermes = ChatBackend.hermes
        if defaults.string(forKey: hermes.endpointStorageKey) == nil,
           let legacy = defaults.string(forKey: "chat_endpoint") ?? defaults.string(forKey: "hermes_endpoint") {
            defaults.set(legacy, forKey: hermes.endpointStorageKey)
        }
        if defaults.string(forKey: hermes.apiKeyStorageKey) == nil,
           let legacy = defaults.string(forKey: "chat_api_key") ?? defaults.string(forKey: "hermes_api_key") {
            defaults.set(legacy, forKey: hermes.apiKeyStorageKey)
        }
    }

    // MARK: - Service Lifecycle

    /// Creates all service objects and wires them into the ConversationController.
    ///
    /// Called once on app launch from the root view's `onAppear`. Subsequent calls
    /// are no-ops unless `reinitializeServices()` resets the flag.
    func initializeServices() {
        guard !servicesInitialized else { return }
        servicesInitialized = true

        let backend = ChatBackend.current
        let config = BackendConfig(
            endpoint: backend.savedEndpoint(),
            apiKey: backend.savedAPIKey(),
            model: backend.defaultModel
        )
        let ws: any ChatTransport = backend.makeTransport(config)
        self.chatTransport = ws

        // Observe connection state.
        connectionCancellable = ws.connectionStatePublisher
            .receive(on: RunLoop.main)
            .map { $0 == .connected }
            .assign(to: \.isConnected, on: self)

        let ttsService: any TTSServiceProtocol = makeTTSService()

        let sttService = STTService()
        let audioPlayer = AudioPlayerService()

        let controller = ConversationController(
            chatTransport: ws,
            ttsService: ttsService,
            sttService: sttService,
            audioPlayer: audioPlayer,
            history: conversationHistory,
            characterController: characterManager
        )
        controller.ttsEnabled = ttsEnabled
        conversationController = controller

        // Verify gateway reachability (HTTP health check).
        ws.connect()

        // Load the configured VRM character model from Resources/VRMModel.
        characterManager.loadModel(named: effectiveVRMModelFilename)

        // Trigger launch greeting after model loads.
        controller.triggerLaunchGreeting()
    }

    private func makeTTSService() -> any TTSServiceProtocol {
        switch TTSProvider(rawValue: ttsProvider) ?? .miniMax {
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

    /// Tears down existing services and recreates them with current settings.
    ///
    /// Call this after the user saves updated API keys or model preferences
    /// in SettingsView so the new values take effect immediately.
    func reinitializeServices() {
        // Cancel any ongoing conversation processing.
        conversationController?.cancel()

        // Tear down the existing chat transport.
        chatTransport?.disconnect()
        connectionCancellable = nil

        // Reset the initialization flag and recreate everything.
        servicesInitialized = false
        initializeServices()
    }
}

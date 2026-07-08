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
    @AppStorage(TTSProvider.storageKey) var ttsProvider: String = TTSProvider.apple.rawValue

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

    /// Apple on-device TTS: empty = auto-pick the best installed voice for the current language.
    @AppStorage("apple_tts_voice_identifier") var appleTTSVoiceIdentifier: String = AppleTTSService.autoVoiceIdentifier

    @AppStorage("apple_tts_rate") var appleTTSRate: Double = AppleTTSService.defaultRate

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

    /// Which STT provider to use for voice input.
    @AppStorage(STTProvider.storageKey) var sttProvider: String = STTProvider.apple.rawValue

    /// Per-provider STT settings.
    @AppStorage("stt_endpoint_groq") var sttEndpointGroq: String = "https://api.groq.com/openai"
    @AppStorage("stt_api_key_groq") var sttAPIKeyGroq: String = ""
    @AppStorage("stt_model_groq") var sttModelGroq: String = "whisper-large-v3-turbo"

    @AppStorage("stt_endpoint_openAI") var sttEndpointOpenAI: String = "https://api.openai.com"
    @AppStorage("stt_api_key_openAI") var sttAPIKeyOpenAI: String = ""
    @AppStorage("stt_model_openAI") var sttModelOpenAI: String = "whisper-1"

    @AppStorage("stt_endpoint_compatible") var sttEndpointCompatible: String = "http://127.0.0.1:8000"
    @AppStorage("stt_api_key_compatible") var sttAPIKeyCompatible: String = ""
    @AppStorage("stt_model_compatible") var sttModelCompatible: String = "whisper-1"

    /// Hands-free voice mode: continuously re-arm the mic after each turn (half-duplex).
    @AppStorage("voice_hands_free_enabled") var voiceHandsFreeEnabled: Bool = false

    /// Full-duplex (voice barge-in) — a sub-option of hands-free that routes audio through a
    /// voice-processing (VPIO) engine so the user can talk over her. Slightly alters her voice.
    @AppStorage("voice_full_duplex_enabled") var voiceFullDuplexEnabled: Bool = false

    /// VRM model filename under Resources/VRMModel.
    @AppStorage("vrm_model_filename") var vrmModelFilename: String = "AliciaSolid.vrm"

    /// Whether 小光 may capture the screen to "see" what you're working on. Off by default;
    /// enabling it prompts for macOS Screen Recording permission (see `ScreenVisionService`).
    @AppStorage("screen_vision_enabled") var screenVisionEnabled: Bool = false

    /// What screen vision captures — the focused window (default) or the whole screen.
    @AppStorage(ScreenVisionScope.storageKey) var screenVisionScope: String = ScreenVisionScope.focusedWindow.rawValue

    /// How often (in minutes) 小光 glances at your screen proactively while vision is on.
    @AppStorage("vision_proactive_interval_minutes") var visionProactiveIntervalMinutes: Int = 5

    /// Whether live transcription of the Mac's system audio is on. Off by default; enabling it
    /// prompts for macOS Screen Recording permission (ScreenCaptureKit audio capture).
    @AppStorage("live_transcription_enabled") var liveTranscriptionEnabled: Bool = false

    /// Source language being transcribed (independent of the app/UI language).
    @AppStorage(LiveCaptionSourceLanguage.storageKey) var liveTranscriptionSourceLanguage: String
        = LiveCaptionSourceLanguage.japanese.rawValue

    /// Whether captions are translated (Phase 2) — on-device Apple Translation when the pack
    /// for the pair is installed; otherwise captions stay in the source language.
    @AppStorage("live_transcription_translate_enabled") var liveTranscriptionTranslateEnabled: Bool = false

    /// The language captions are translated into.
    @AppStorage(LiveCaptionTargetLanguage.storageKey) var liveTranscriptionTargetLanguage: String
        = LiveCaptionTargetLanguage.traditionalChinese.rawValue

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

    /// Captures what the user is working on so 小光 can "see" the screen. Long-lived so it tracks
    /// the user's active app across the whole session (see `ScreenVisionService`); gated by
    /// `screenVisionEnabled`. Not `@Published` — nothing observes it reactively.
    let screenVisionService = ScreenVisionService()

    /// Live transcription of the Mac's system audio (SCK audio → Apple STT → captions).
    /// Long-lived and independent of `reinitializeServices()` (a Settings save shouldn't cut a
    /// running caption session unless its own settings changed — `apply` reconciles).
    let liveTranscription = LiveTranscriptionController()

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

        // Keep the screen-vision capture scope in sync with the saved preference.
        screenVisionService.scope = ScreenVisionScope(rawValue: screenVisionScope) ?? .focusedWindow

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

        let sttService: any STTServiceProtocol = makeSTTService()
        let audioPlayer = AudioPlayerService()

        let controller = ConversationController(
            chatTransport: ws,
            ttsService: ttsService,
            sttService: sttService,
            screenVisionService: screenVisionService,
            audioPlayer: audioPlayer,
            history: conversationHistory,
            characterController: characterManager
        )
        controller.ttsEnabled = ttsEnabled
        controller.screenVisionEnabled = screenVisionEnabled
        controller.visionProactiveIntervalSeconds = Double(visionProactiveIntervalMinutes * 60)
        controller.configureVoiceMode(handsFree: voiceHandsFreeEnabled, fullDuplex: voiceFullDuplexEnabled)
        conversationController = controller

        // Verify gateway reachability (HTTP health check).
        ws.connect()

        // Live transcription: captions go to the same pet bubble the conversation uses, so it
        // defers to her while she's speaking; `apply` starts/stops/restarts per saved settings.
        liveTranscription.characterController = characterManager
        liveTranscription.isCharacterSpeaking = { [weak self] in
            self?.conversationController?.isSpeaking ?? false
        }
        applyLiveTranscriptionSettings()

        // Load the configured VRM character model from Resources/VRMModel.
        characterManager.loadModel(named: effectiveVRMModelFilename)

        // Trigger launch greeting after model loads.
        controller.triggerLaunchGreeting()
    }

    private func makeSTTService() -> any STTServiceProtocol {
        let provider = STTProvider(rawValue: sttProvider) ?? .apple
        switch provider {
        case .apple:
            return STTService()
        case .groq:
            return WhisperSTTService(
                endpoint: sttEndpointGroq,
                apiKey: sttAPIKeyGroq,
                model: sttModelGroq
            )
        case .openAI:
            return WhisperSTTService(
                endpoint: sttEndpointOpenAI,
                apiKey: sttAPIKeyOpenAI,
                model: sttModelOpenAI
            )
        case .openAICompatible:
            return WhisperSTTService(
                endpoint: sttEndpointCompatible,
                apiKey: sttAPIKeyCompatible,
                model: sttModelCompatible
            )
        }
    }

    private func makeTTSService() -> any TTSServiceProtocol {
        switch TTSProvider(rawValue: ttsProvider) ?? .apple {
        case .apple:
            return AppleTTSService(
                voiceIdentifier: appleTTSVoiceIdentifier,
                rate: appleTTSRate
            )
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

    /// Reconcile the live-transcription session with the saved settings (start/stop/restart).
    func applyLiveTranscriptionSettings() {
        liveTranscription.apply(
            enabled: liveTranscriptionEnabled,
            source: LiveCaptionSourceLanguage(rawValue: liveTranscriptionSourceLanguage) ?? .japanese,
            translate: liveTranscriptionTranslateEnabled,
            target: LiveCaptionTargetLanguage(rawValue: liveTranscriptionTargetLanguage) ?? .traditionalChinese
        )
    }

    /// Tears down existing services and recreates them with current settings.
    ///
    /// Call this after the user saves updated API keys or model preferences
    /// in SettingsView so the new values take effect immediately.
    func reinitializeServices() {
        // Fully tear down voice mode on the outgoing controller so its VPIO engine releases the
        // mic before a new controller spins one up (two VPIO engines would fight over the input).
        conversationController?.configureVoiceMode(handsFree: false, fullDuplex: false)

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

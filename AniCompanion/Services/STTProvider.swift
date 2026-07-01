import Foundation

enum STTProvider: String, CaseIterable, Identifiable, Sendable {
    case apple
    case groq
    case openAI
    case openAICompatible

    var id: String { rawValue }

    static let storageKey = "stt_provider"

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .groq: return "Groq"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    var configHint: String {
        switch self {
        case .apple:
            return "On-device speech recognition via Apple Speech Framework. No API key needed."
        case .groq:
            return "Groq Whisper API — fast cloud transcription."
        case .openAI:
            return "OpenAI Whisper / GPT-4o transcription API."
        case .openAICompatible:
            return "Any Whisper-compatible endpoint (self-hosted, etc.). POST /v1/audio/transcriptions."
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .apple: return ""
        case .groq: return "https://api.groq.com/openai"
        case .openAI: return "https://api.openai.com"
        case .openAICompatible: return "http://127.0.0.1:8000"
        }
    }

    var defaultModel: String {
        switch self {
        case .apple: return ""
        case .groq: return "whisper-large-v3-turbo"
        case .openAI: return "whisper-1"
        case .openAICompatible: return "whisper-1"
        }
    }

    var availableModels: [String] {
        switch self {
        case .apple: return []
        case .groq: return ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .openAI: return ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
        case .openAICompatible: return []
        }
    }

    static var current: STTProvider {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let provider = STTProvider(rawValue: raw) {
            return provider
        }
        return .apple
    }
}

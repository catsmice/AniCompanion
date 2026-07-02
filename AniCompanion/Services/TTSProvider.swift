import Foundation

enum TTSProvider: String, CaseIterable, Identifiable, Sendable {
    case miniMax
    case blueMagpie
    case openAI

    var id: String { rawValue }

    static let storageKey = "tts_provider"

    var displayName: String {
        switch self {
        case .miniMax: return "MiniMax"
        case .blueMagpie: return "BlueMagpie"
        case .openAI: return "OpenAI"
        }
    }

    static var current: TTSProvider {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let provider = TTSProvider(rawValue: raw) {
            return provider
        }
        return .miniMax
    }
}

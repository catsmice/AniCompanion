import Foundation

/// The character's emotion set, parsed from LLM `[emotion]` tags. Carries the MiniMax TTS emotion
/// parameter and a localized display name; the emotion → VRM expression mapping lives in
/// `ThreeVRMCharacterManager`.
enum Emotion: String, CaseIterable, Codable, Sendable {
    case neutral
    case happy
    case sad
    case angry
    case surprised
    case curious
    case excited
    case shy
    case love
    case smirk
    case sleepy
    case proud
    case disgusted
    case pain
    case laugh
    case bored

    // MARK: - TTS Emotion

    /// MiniMax TTS emotion_category parameter value.
    var ttsEmotionCategory: String? {
        switch self {
        case .neutral:    return nil
        case .happy:      return "happy"
        case .sad:        return "sad"
        case .angry:      return "angry"
        case .surprised:  return "surprised"
        case .curious:    return nil
        case .excited:    return "happy"
        case .shy:        return nil
        case .love:       return "happy"
        case .smirk:      return nil
        case .sleepy:     return nil
        case .proud:      return "happy"
        case .disgusted:  return "angry"
        case .pain:       return "sad"
        case .laugh:      return "happy"
        case .bored:      return nil
        }
    }

    // MARK: - Display

    /// Localized display name for UI.
    var displayName: String {
        switch self {
        case .neutral:    return String(localized: "Neutral", comment: "Emotion name")
        case .happy:      return String(localized: "Happy", comment: "Emotion name")
        case .sad:        return String(localized: "Sad", comment: "Emotion name")
        case .angry:      return String(localized: "Angry", comment: "Emotion name")
        case .surprised:  return String(localized: "Surprised", comment: "Emotion name")
        case .curious:    return String(localized: "Curious", comment: "Emotion name")
        case .excited:    return String(localized: "Excited", comment: "Emotion name")
        case .shy:        return String(localized: "Shy", comment: "Emotion name")
        case .love:       return String(localized: "Love", comment: "Emotion name")
        case .smirk:      return String(localized: "Smirk", comment: "Emotion name")
        case .sleepy:     return String(localized: "Sleepy", comment: "Emotion name")
        case .proud:      return String(localized: "Proud", comment: "Emotion name")
        case .disgusted:  return String(localized: "Disgusted", comment: "Emotion name")
        case .pain:       return String(localized: "Pain", comment: "Emotion name")
        case .laugh:      return String(localized: "Laugh", comment: "Emotion name")
        case .bored:      return String(localized: "Bored", comment: "Emotion name")
        }
    }

    // MARK: - Parsing

    /// Parse an emotion tag from LLM output (e.g., "[happy]" -> .happy).
    static func from(tag: String) -> Emotion? {
        let cleaned = tag
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        return Emotion(rawValue: cleaned)
    }
}

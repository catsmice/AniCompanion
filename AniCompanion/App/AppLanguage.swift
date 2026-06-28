import Foundation

/// The app's supported languages (UI + character persona + speech recognition).
///
/// To add a language:
///   1. Add a case here with its BCP-47 code.
///   2. Add a `Resources/Persona/<code>/` folder (system_prompt.txt + proactive.json).
///   3. Add the language's column in `Localizable.xcstrings` (the UI strings).
///   4. Map a speech-recognition locale below.
/// See CONTRIBUTING.md for the full walkthrough.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    /// Endonym — each language's name written in that language (for the picker).
    var displayName: String {
        switch self {
        case .english:            return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }

    /// Locale identifier for on-device speech recognition (region/accent-specific).
    var sttLocaleIdentifier: String {
        switch self {
        case .english:            return "en-US"
        case .traditionalChinese: return "zh-Hant-TW"
        }
    }

    /// `@AppStorage` key shared across the app for the selected language.
    static let storageKey = "app_language"

    /// The currently selected language: the persisted choice if set, otherwise the
    /// system language when supported, otherwise English.
    static var current: AppLanguage {
        if let code = UserDefaults.standard.string(forKey: storageKey),
           let language = AppLanguage(rawValue: code) {
            return language
        }
        return systemDefault
    }

    /// The supported language closest to the user's system language (English fallback).
    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW")
            || preferred.hasPrefix("zh-HK") || preferred.hasPrefix("zh-MO") {
            return .traditionalChinese
        }
        return .english
    }

    /// `Locale` used for formatting things like the current time in prompts.
    var locale: Locale { Locale(identifier: rawValue) }
}

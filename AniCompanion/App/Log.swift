import os

// MARK: - Log

/// Centralized logging for AniCompanion, replacing ad-hoc `print()` debugging.
///
/// Each category forwards to an `os.Logger` at `.debug` level, so these lines are filtered
/// out of release logs by the unified logging system and never spam stdout. View them live
/// in Console.app or with:
///   `log stream --predicate 'subsystem == "com.anicompanion.app"'`
///
/// Messages are passed as plain `String`s (built eagerly at the call site, like `print`).
/// **Do not interpolate user content** (recognized speech, model output, captions) into a log
/// message — log a shape instead (e.g. character count). The pipeline sites that handle such
/// content already do this.
enum Log {
    private static let subsystem = "com.anicompanion.app"

    private static let pipelineLog = Logger(subsystem: subsystem, category: "Pipeline")
    private static let sttLog = Logger(subsystem: subsystem, category: "STT")
    private static let ttsLog = Logger(subsystem: subsystem, category: "TTS")
    private static let audioLog = Logger(subsystem: subsystem, category: "Audio")
    private static let characterLog = Logger(subsystem: subsystem, category: "Character")
    private static let renderLog = Logger(subsystem: subsystem, category: "Render")
    private static let animationLog = Logger(subsystem: subsystem, category: "Animation")

    static func pipeline(_ message: String) { pipelineLog.debug("\(message, privacy: .public)") }
    static func stt(_ message: String) { sttLog.debug("\(message, privacy: .public)") }
    static func tts(_ message: String) { ttsLog.debug("\(message, privacy: .public)") }
    static func audio(_ message: String) { audioLog.debug("\(message, privacy: .public)") }
    static func character(_ message: String) { characterLog.debug("\(message, privacy: .public)") }
    static func render(_ message: String) { renderLog.debug("\(message, privacy: .public)") }
    static func animation(_ message: String) { animationLog.debug("\(message, privacy: .public)") }
}

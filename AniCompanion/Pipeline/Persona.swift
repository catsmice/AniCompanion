import Foundation

/// Localized character persona text, loaded from `Resources/Persona/<language>/`:
/// the system prompt plus the proactive (greeting / idle) prompt templates.
///
/// Falls back to English, then to a minimal built-in default, if a resource is missing —
/// so a partial translation never leaves the app without a prompt.
struct Persona: Sendable {
    let systemPrompt: String
    let launchGreetingTemplate: String
    let idlePromptTemplate: String
    let idleTasks: [String]
    /// Proactive prompt used (instead of an idle task) when screen vision is on: she looks at the
    /// attached screenshot and comments only if it's genuinely worthwhile, else stays quiet.
    let visionGlanceTemplate: String
    /// Hidden context injected into chat turns while live transcription runs, carrying the
    /// recent transcript of what's playing so she can be asked about it ({transcript}).
    let transcriptContextTemplate: String

    static func load(language: AppLanguage) -> Persona {
        let systemPrompt = loadText("system_prompt", ext: "txt", language: language)
            ?? loadText("system_prompt", ext: "txt", language: .english)
            ?? Self.fallbackSystemPrompt

        let proactive = ProactivePrompts.load(language: language)
            ?? ProactivePrompts.load(language: .english)
            ?? ProactivePrompts.fallback

        return Persona(
            systemPrompt: systemPrompt,
            launchGreetingTemplate: proactive.launchGreetingTemplate,
            idlePromptTemplate: proactive.idlePromptTemplate,
            idleTasks: proactive.idleTasks,
            visionGlanceTemplate: proactive.visionGlanceTemplate ?? Self.defaultVisionGlanceTemplate,
            transcriptContextTemplate: proactive.transcriptContextTemplate ?? Self.defaultTranscriptContextTemplate
        )
    }

    /// Built-in fallback for the transcript context, used when a `proactive.json` predates the field.
    static let defaultTranscriptContextTemplate = """
    Your Master has live transcription on — you're both following along with audio playing on \
    their Mac (a video, a stream, a meeting). Recent transcript (original, with translation \
    where available):

    {transcript}

    Use this as shared context: if your Master asks about "what she said" or something from the \
    video, answer from the transcript. Don't recite or summarize it unprompted.
    """

    /// Built-in fallback for the vision glance, used when a `proactive.json` predates the field.
    static let defaultVisionGlanceTemplate = """
    Current time: {time}
    You can see your Master's screen right now (attached). Glance at it. If there's something \
    genuinely worth reacting to — a problem or error you could help with, something interesting, or \
    something fun to comment on in character — say it briefly and naturally. If it's mundane, looks \
    private/sensitive, or you have nothing worthwhile to add, reply with exactly [silent] and \
    nothing else. Don't narrate or explain your silence — either say something genuinely useful, or \
    output [silent].
    """

    // MARK: - Resource loading

    private static func loadText(_ name: String, ext: String, language: AppLanguage) -> String? {
        guard let url = Bundle.main.url(
            forResource: name, withExtension: ext, subdirectory: "Persona/\(language.rawValue)")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static let fallbackSystemPrompt = """
    You are a friendly virtual companion character. Reply in the user's language. Begin each \
    utterance with an emotion tag like [happy], [sad], [curious], or [neutral]. Keep replies \
    concise and conversational.
    """
}

/// Decodes `proactive.json` for a language.
private struct ProactivePrompts: Decodable {
    let launchGreetingTemplate: String
    let idlePromptTemplate: String
    let idleTasks: [String]
    /// Optional so older/partial `proactive.json` files still decode; `Persona` supplies a default.
    let visionGlanceTemplate: String?
    let transcriptContextTemplate: String?

    static func load(language: AppLanguage) -> ProactivePrompts? {
        guard let url = Bundle.main.url(
            forResource: "proactive", withExtension: "json", subdirectory: "Persona/\(language.rawValue)"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProactivePrompts.self, from: data)
    }

    static let fallback = ProactivePrompts(
        launchGreetingTemplate: "Current time: {time}\nThe user just came online. Greet them naturally.",
        idlePromptTemplate: "Current time: {time}\nTask: {task}",
        idleTasks: ["Share something interesting you thought of with the user."],
        visionGlanceTemplate: nil,
        transcriptContextTemplate: nil
    )
}

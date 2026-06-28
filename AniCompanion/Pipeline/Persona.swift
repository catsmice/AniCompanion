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
            idleTasks: proactive.idleTasks
        )
    }

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

    static func load(language: AppLanguage) -> ProactivePrompts? {
        guard let url = Bundle.main.url(
            forResource: "proactive", withExtension: "json", subdirectory: "Persona/\(language.rawValue)"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProactivePrompts.self, from: data)
    }

    static let fallback = ProactivePrompts(
        launchGreetingTemplate: "Current time: {time}\nThe user just came online. Greet them naturally.",
        idlePromptTemplate: "Current time: {time}\nTask: {task}",
        idleTasks: ["Share something interesting you thought of with the user."]
    )
}

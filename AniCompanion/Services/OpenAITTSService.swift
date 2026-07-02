import Foundation

final class OpenAITTSService: TTSServiceProtocol, Sendable {
    static let defaultModel = "gpt-4o-mini-tts"
    static let defaultVoice = "coral"
    static let defaultInstructions = "Speak naturally, warm and expressive."

    static let modelOptions = [
        "gpt-4o-mini-tts",
        "tts-1",
        "tts-1-hd"
    ]

    struct VoiceOption: Identifiable, Sendable {
        let id: String
        let englishTrait: String
        let traditionalChineseTrait: String
        let isRecommended: Bool

        func menuLabel(language: AppLanguage) -> String {
            let label = "\(id) - \(trait(language: language))"
            guard isRecommended else { return label }

            switch language {
            case .english:
                return "\(label) (recommended)"
            case .traditionalChinese:
                return "\(label)（推薦）"
            }
        }

        func detailLabel(language: AppLanguage) -> String {
            let detail = trait(language: language)
            guard isRecommended else { return detail }

            switch language {
            case .english:
                return "\(detail). Recommended by OpenAI for best quality."
            case .traditionalChinese:
                return "\(detail)。OpenAI 建議作為最佳品質選項。"
            }
        }

        private func trait(language: AppLanguage) -> String {
            switch language {
            case .english:
                return englishTrait
            case .traditionalChinese:
                return traditionalChineseTrait
            }
        }
    }

    // The API only receives the voice ID. These short traits are UI hints for quicker auditioning.
    static let voiceOptions = [
        VoiceOption(id: "alloy", englishTrait: "balanced, neutral", traditionalChineseTrait: "平衡、中性", isRecommended: false),
        VoiceOption(id: "ash", englishTrait: "clear, composed", traditionalChineseTrait: "清晰、沉穩", isRecommended: false),
        VoiceOption(id: "ballad", englishTrait: "soft, lyrical", traditionalChineseTrait: "柔和、敘事感", isRecommended: false),
        VoiceOption(id: "coral", englishTrait: "bright, warm", traditionalChineseTrait: "明亮、溫暖", isRecommended: false),
        VoiceOption(id: "echo", englishTrait: "crisp, direct", traditionalChineseTrait: "清脆、直接", isRecommended: false),
        VoiceOption(id: "fable", englishTrait: "expressive, storyteller", traditionalChineseTrait: "有表情、說故事感", isRecommended: false),
        VoiceOption(id: "nova", englishTrait: "friendly, energetic", traditionalChineseTrait: "親切、有活力", isRecommended: false),
        VoiceOption(id: "onyx", englishTrait: "deep, grounded", traditionalChineseTrait: "低沉、穩重", isRecommended: false),
        VoiceOption(id: "sage", englishTrait: "calm, thoughtful", traditionalChineseTrait: "冷靜、思考感", isRecommended: false),
        VoiceOption(id: "shimmer", englishTrait: "light, upbeat", traditionalChineseTrait: "輕快、活潑", isRecommended: false),
        VoiceOption(id: "verse", englishTrait: "smooth, expressive", traditionalChineseTrait: "順暢、有表情", isRecommended: false),
        VoiceOption(id: "marin", englishTrait: "natural, high-quality", traditionalChineseTrait: "自然、高品質", isRecommended: true),
        VoiceOption(id: "cedar", englishTrait: "steady, high-quality", traditionalChineseTrait: "穩定、高品質", isRecommended: true)
    ]

    private static let legacyModels: Set<String> = ["tts-1", "tts-1-hd"]

    static let legacyVoiceIDs = [
        "alloy",
        "ash",
        "coral",
        "echo",
        "fable",
        "onyx",
        "nova",
        "sage",
        "shimmer"
    ]

    static func voiceOptions(for model: String) -> [VoiceOption] {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if legacyModels.contains(trimmed) {
            return voiceOptions.filter { legacyVoiceIDs.contains($0.id) }
        }
        return voiceOptions
    }

    static func voiceDetail(for voice: String, model: String, language: AppLanguage) -> String {
        guard let option = voiceOptions(for: model).first(where: { $0.id == voice }) else {
            return ""
        }
        return option.detailLabel(language: language)
    }

    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String
    private let speed: Double
    private let session: URLSession

    init(
        apiKey: String,
        model: String = OpenAITTSService.defaultModel,
        voice: String = OpenAITTSService.defaultVoice,
        instructions: String = OpenAITTSService.defaultInstructions,
        speed: Double = 1.0
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.speed = speed

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedText.isEmpty else {
                        continuation.finish(throwing: TTSError.emptyText)
                        return
                    }

                    let request = try buildRequest(text: trimmedText, emotion: emotion)
                    let (data, response) = try await session.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TTSError.invalidResponse)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        if httpResponse.statusCode == 401 {
                            continuation.finish(throwing: TTSError.unauthorized)
                        } else {
                            continuation.finish(throwing: TTSError.requestFailed(
                                statusCode: httpResponse.statusCode,
                                body: body
                            ))
                        }
                        return
                    }

                    guard !data.isEmpty else {
                        continuation.finish(throwing: TTSError.decodingError("OpenAI returned empty audio data."))
                        return
                    }

                    continuation.yield(data)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func buildRequest(text: String, emotion: Emotion) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TTSError.unauthorized
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": effectiveModel,
            "input": text,
            "voice": effectiveVoice,
            "response_format": "wav",
            "speed": effectiveSpeed
        ]

        if supportsInstructions, let instructionText = instructionText(for: emotion) {
            body["instructions"] = instructionText
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultModel : trimmed
    }

    private var effectiveVoice: String {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = Self.voiceOptions(for: effectiveModel)
        if trimmed.isEmpty || !options.contains(where: { $0.id == trimmed }) {
            return Self.defaultVoice
        }
        return trimmed
    }

    private var effectiveSpeed: Double {
        min(max(speed, 0.25), 4.0)
    }

    private var supportsInstructions: Bool {
        !Self.legacyModels.contains(effectiveModel)
    }

    private func instructionText(for emotion: Emotion) -> String? {
        let custom = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom.isEmpty ? Self.defaultInstructions : custom

        switch emotion {
        case .neutral:
            return base
        case .happy, .excited, .laugh:
            return "\(base) Sound upbeat and cheerful."
        case .sad, .pain:
            return "\(base) Sound gentle and sympathetic."
        case .angry, .disgusted:
            return "\(base) Sound firm, but not harsh."
        case .surprised:
            return "\(base) Sound pleasantly surprised."
        case .curious:
            return "\(base) Sound curious and engaged."
        case .shy:
            return "\(base) Sound soft and a little shy."
        case .love:
            return "\(base) Sound affectionate and warm."
        case .smirk:
            return "\(base) Sound playful and teasing."
        case .sleepy, .bored:
            return "\(base) Sound relaxed and low-energy."
        case .proud:
            return "\(base) Sound confident and pleased."
        }
    }
}

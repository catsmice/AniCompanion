import Foundation
@preconcurrency import AVFoundation

/// On-device text-to-speech using Apple's `AVSpeechSynthesizer`.
///
/// Unlike the cloud providers, this needs no API key and no network — it renders speech
/// entirely on-device using the voices installed in macOS. It fits the same
/// `TTSServiceProtocol` contract by using `AVSpeechSynthesizer.write(_:toBufferCallback:)`
/// to *render* (not play) the utterance into PCM buffers, which we write out as WAV `Data`.
/// That WAV flows through the existing `AudioPlayerService` decode → RMS lip-sync → `AudioQueue`
/// path untouched (it already sniffs the RIFF/WAVE magic bytes).
///
/// Voice quality depends on what the user has installed: the pre-installed *compact* voices
/// sound robotic; the natural *Enhanced/Premium* variants are a one-time download in
/// System Settings → Accessibility → Spoken Content → Manage Voices.
final class AppleTTSService: TTSServiceProtocol, Sendable {

    /// A stored empty voice identifier means "auto-pick the best installed voice."
    static let autoVoiceIdentifier = ""

    /// Default utterance rate — equal to `AVSpeechUtteranceDefaultSpeechRate` (0.5).
    static let defaultRate: Double = 0.5

    private let voiceIdentifier: String?
    private let rate: Double

    /// - Parameters:
    ///   - voiceIdentifier: An `AVSpeechSynthesisVoice.identifier`, or empty/nil to auto-pick
    ///     the best installed voice for the current app language at synthesis time.
    ///   - rate: Utterance rate in the `AVSpeechUtterance` 0.0...1.0 scale (default 0.5).
    init(voiceIdentifier: String? = nil, rate: Double = AppleTTSService.defaultRate) {
        let trimmed = voiceIdentifier?.trimmingCharacters(in: .whitespaces)
        self.voiceIdentifier = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.rate = rate
    }

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        let voiceIdentifier = resolvedVoiceIdentifier()
        let rate = self.rate
        let pitch = Self.pitchMultiplier(for: emotion)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        continuation.finish(throwing: TTSError.emptyText)
                        return
                    }

                    let wav = try await AppleSpeechRenderer.render(
                        text: trimmed,
                        voiceIdentifier: voiceIdentifier,
                        rate: Float(rate),
                        pitch: pitch
                    )
                    try Task.checkCancellation()

                    guard !wav.isEmpty else {
                        continuation.finish(throwing: TTSError.decodingError("Apple TTS produced no audio."))
                        return
                    }
                    continuation.yield(wav)
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

    /// Resolve the voice to use: the configured one if still installed, else auto-pick.
    private func resolvedVoiceIdentifier() -> String? {
        if let voiceIdentifier,
           AVSpeechSynthesisVoice(identifier: voiceIdentifier) != nil {
            return voiceIdentifier
        }
        return Self.bestVoiceIdentifier(for: AppLanguage.current)
    }

    // MARK: - Emotion → prosody

    /// A subtle pitch nudge per emotion — `AVSpeechUtterance` has no real emotional TTS,
    /// only rate/pitch/volume, so we keep this gentle.
    private static func pitchMultiplier(for emotion: Emotion) -> Float {
        switch emotion {
        case .neutral, .curious, .proud: return 1.0
        case .happy, .love, .laugh:      return 1.10
        case .excited, .surprised:       return 1.15
        case .shy, .smirk:               return 1.05
        case .sad, .pain:                return 0.90
        case .angry, .disgusted:         return 0.95
        case .sleepy, .bored:            return 0.92
        }
    }

    // MARK: - Voice discovery

    struct VoiceOption: Identifiable, Sendable {
        let id: String       // AVSpeechSynthesisVoice.identifier
        let name: String     // display name, e.g. "美佳"
        let qualityLabel: String  // "", "Enhanced", "Premium"
        let languageCode: String  // BCP-47 tag, e.g. "zh-TW" / "zh-CN"
    }

    /// Installed voices for the given app language, best quality first, novelty voices excluded.
    static func voiceOptions(for language: AppLanguage) -> [VoiceOption] {
        matchingVoices(for: language)
            .sorted { qualityRank($0.quality) > qualityRank($1.quality) }
            .map { voice in
                VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    qualityLabel: qualityLabel(voice.quality),
                    languageCode: voice.language
                )
            }
    }

    /// Auto-pick the best installed voice identifier for a language, or nil if none match.
    static func bestVoiceIdentifier(for language: AppLanguage) -> String? {
        matchingVoices(for: language)
            .max(by: { qualityRank($0.quality) < qualityRank($1.quality) })?
            .identifier
    }

    /// Voices whose language matches, preferring the "real" TTS voices (compact/enhanced/premium)
    /// over the novelty voices (Bells, Boing, …) that share a language tag.
    private static func matchingVoices(for language: AppLanguage) -> [AVSpeechSynthesisVoice] {
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            languageMatches($0.language, for: language)
        }
        let real = matching.filter { voice in
            let id = voice.identifier.lowercased()
            return id.contains(".premium.") || id.contains(".enhanced.") || id.contains(".compact.")
        }
        return real.isEmpty ? matching : real
    }

    /// Whether a voice's BCP-47 language tag is usable for the given app language.
    private static func languageMatches(_ voiceLanguage: String, for language: AppLanguage) -> Bool {
        let lang = voiceLanguage.lowercased()
        switch language {
        case .english:
            return lang.hasPrefix("en")
        case .traditionalChinese:
            // Mandarin Chinese — Taiwan (zh-TW) and Mainland (zh-CN) share spoken Mandarin, and the
            // premium/Siri voices ship only as zh-CN, so include both. Exclude Cantonese (zh-HK /
            // yue-*), which would mispronounce Mandarin text.
            return lang.hasPrefix("zh") && !lang.hasPrefix("zh-hk") && !lang.hasPrefix("yue")
        }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:  return 3
        case .enhanced: return 2
        case .default:  return 1
        @unknown default: return 0
        }
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        case .default:  return ""
        @unknown default: return ""
        }
    }
}

// MARK: - Offline renderer

/// Renders one utterance to WAV `Data` using `AVSpeechSynthesizer.write`.
///
/// `@unchecked Sendable`: the buffer callback fires on the synthesizer's internal thread.
/// Access to the mutable rendering state is serialized by `lock`, and the class instance is
/// kept alive for the whole render by the suspended `run(...)` call awaiting its continuation.
private final class AppleSpeechRenderer: @unchecked Sendable {

    static func render(text: String, voiceIdentifier: String?, rate: Float, pitch: Float) async throws -> Data {
        try await AppleSpeechRenderer().run(text: text, voiceIdentifier: voiceIdentifier, rate: rate, pitch: pitch)
    }

    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var continuation: CheckedContinuation<Data, Error>?
    private var didFinish = false
    private var wroteAudio = false

    /// Safety net: if `write` never delivers its terminal (zero-length) buffer — a documented
    /// flakiness for unavailable/mismatched voices — fail instead of hanging the continuation
    /// (and leaking the synth + temp file) forever. TTS renders far faster than real time, so a
    /// generous fixed timeout only ever catches a true hang.
    private let renderTimeout: TimeInterval = 20

    private func run(text: String, voiceIdentifier: String?, rate: Float, pitch: Float) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.continuation = cont

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            self.outputURL = url

            // `AVSpeechSynthesizer.write` delivers its buffer callbacks on the run loop of the
            // thread that called it. Our caller is a background `Task` with no run loop, so we
            // must issue the `write` from the main queue (whose run loop is always live in a GUI
            // app) or the callbacks — and this continuation — would never fire.
            DispatchQueue.main.async { [self] in
                let utterance = AVSpeechUtterance(string: text)
                if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                    utterance.voice = voice
                }
                utterance.rate = rate
                utterance.pitchMultiplier = pitch

                let synth = AVSpeechSynthesizer()
                self.synthesizer = synth

                synth.write(utterance) { [weak self] buffer in
                    guard let self else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else {
                        self.finish(.failure(TTSError.decodingError("Unexpected buffer type from AVSpeechSynthesizer.")))
                        return
                    }

                    // A zero-length buffer signals the end of the utterance.
                    if pcm.frameLength == 0 {
                        self.finishSuccess()
                        return
                    }

                    do {
                        if self.audioFile == nil {
                            self.audioFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                        }
                        try self.audioFile?.write(from: pcm)
                        self.wroteAudio = true
                    } catch {
                        self.finish(.failure(TTSError.decodingError("Failed to write TTS audio: \(error.localizedDescription)")))
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + self.renderTimeout) { [weak self] in
                    self?.finish(.failure(TTSError.decodingError("Apple TTS render timed out.")))
                }
            }
        }
    }

    private func finishSuccess() {
        audioFile = nil // close the file (release the AVAudioFile) before reading it back
        // No non-empty buffers (e.g. punctuation-only text) → return empty so the caller's
        // empty-guard yields a clean "no audio" outcome, not a misleading read error.
        guard wroteAudio, let url = outputURL else { finish(.success(Data())); return }
        finish(.success((try? Data(contentsOf: url)) ?? Data()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !didFinish, let cont = continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        continuation = nil
        let synth = synthesizer
        synthesizer = nil
        let url = outputURL
        lock.unlock()

        // Tear the synth down (esp. when bailing mid-render) and clean up the temp file on every
        // path, then resume exactly once.
        synth?.stopSpeaking(at: .immediate)
        if let url { try? FileManager.default.removeItem(at: url) }
        cont.resume(with: result)
    }
}

import AVFoundation

// MARK: - MicGain

/// User-tunable **microphone input gain**, applied to captured audio *before* it reaches speech
/// recognition — so 小光 can hear soft speech. Boosting the samples helps on two fronts at once:
/// it lifts quiet speech above the RMS silence/barge-in gates, *and* gives the recognizer a
/// stronger signal (better accuracy) than merely lowering thresholds would.
///
/// Read straight from `UserDefaults` (the `stt_input_gain` `@AppStorage` value) so every capture
/// path — Apple STT, Whisper, and full-duplex — shares one setting without threading it through
/// each service's initializer. Capped at 3× so full-duplex's echo-cancelled residual (~0.003 RMS)
/// stays well under the 0.05 barge-in gate, avoiding self-triggered barge-in.
enum MicGain {

    static let storageKey = "stt_input_gain"
    static let defaultValue: Double = 1.0
    static let range: ClosedRange<Double> = 1.0...3.0

    /// The current gain, clamped to `range`. 1.0 = unchanged.
    static var current: Float {
        let stored = UserDefaults.standard.object(forKey: storageKey) as? Double ?? defaultValue
        return Float(min(max(stored, range.lowerBound), range.upperBound))
    }

    /// Multiply a float PCM buffer's samples in place by `current`, hard-clamped to [-1, 1].
    /// No-op at unity gain. Called from the real-time audio tap: the in-place multiply is
    /// allocation-free, but `current` reads `UserDefaults` (in-process cached, not strictly
    /// wait-free) — acceptable here because these taps already do heavier work off the RT budget
    /// (file writes in `WhisperSTTService`, `SFSpeechRecognizer.append`). Apply it to the audio
    /// fed to *recognition*, never before an RMS gate (silence/barge-in) — see those call sites.
    static func apply(to buffer: AVAudioPCMBuffer) {
        let gain = current
        guard gain != 1.0, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for i in 0..<frames {
                let boosted = samples[i] * gain
                samples[i] = boosted > 1 ? 1 : (boosted < -1 ? -1 : boosted)
            }
        }
    }
}

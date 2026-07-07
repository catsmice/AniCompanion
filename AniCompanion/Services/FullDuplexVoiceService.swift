import Foundation
import Speech
// @preconcurrency: we capture a non-Sendable AVAudioPCMBuffer inside AVFAudio's @Sendable tap /
// converter blocks (safe — used synchronously). Same pattern as AudioPlayerService/STTService.
@preconcurrency import AVFoundation

// MARK: - Full-Duplex Voice Service (Phase 2: VPIO barge-in)
//
// Owns ONE Voice-Processing I/O (VPIO) `AVAudioEngine` that simultaneously:
//   • plays her TTS through a player node (with amplitude for lip-sync), and
//   • taps the mic — echo-cancelled by VPIO, so the mic hears (mostly) only the user —
//     feeding a continuous `SFSpeechRecognizer` plus an RMS gate for barge-in.
//
// This is the full-duplex path: the user can talk *over* her. When real user speech is
// detected mid-playback (RMS gate), playback is cut (`onBargeIn`) and the ongoing recognition
// captures the interrupting utterance, delivered via `onUserUtterance` after a silence pause.
//
// It replaces BOTH AudioPlayerService and the half-duplex STT loop while active, and requires
// Apple on-device recognition (the only provider that streams live audio). Half-duplex and
// push-to-talk paths are untouched.
@MainActor
final class FullDuplexVoiceService: ObservableObject {

    // MARK: Published (lip-sync)

    @Published private(set) var currentAmplitude: Float = 0
    @Published private(set) var isSpeaking: Bool = false

    /// Whether the mic is mid-capturing a user utterance, so lazy-VPIO teardown must wait (else a
    /// barge-in would be cut off). True if a partial is buffered / the silence timer is running, OR
    /// we're in the grace window right after a barge-in — which covers the gap between the RMS
    /// trigger and the recognizer's first partial (on-device first-partial latency can exceed the
    /// teardown debounce, which would otherwise drop the interruption).
    var isCapturingUtterance: Bool {
        if lastBargeIn > 0, CACurrentMediaTime() - lastBargeIn < bargeInGrace { return true }
        return silenceTimer != nil || !currentUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Callbacks (set by ConversationController)

    /// Fired the instant user speech interrupts playback — cancel the whole in-flight pipeline.
    var onBargeIn: (() -> Void)?
    /// Fired with a finalized user utterance (after a silence pause) — send it as a turn.
    var onUserUtterance: ((String) -> Void)?

    // MARK: Tunables (barge-in / end-of-utterance)

    /// Post-AEC mic RMS above which we treat input as genuine user speech (not residual echo).
    /// Calibrated on-device: VPIO scrubs her own voice to a ~0.003 floor while the user's voice
    /// reaches 0.16–0.25, so 0.05 sits with wide margin on both sides.
    var bargeInRMSThreshold: Float = 0.05
    /// How long RMS must stay above threshold before we commit to a barge-in.
    var bargeInSustain: TimeInterval = 0.18
    /// Silence after the last partial result that finalizes an utterance.
    var utteranceSilence: TimeInterval = 1.4

    // MARK: State

    private let capture = DuplexCapture()
    private var playbackFormat: AVAudioFormat?
    private var isRunning = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var currentUtterance: String = ""

    /// Bumped each recognition cycle so callbacks from a superseded task are ignored.
    private var recognitionGen: UInt64 = 0

    // Barge-in RMS gating.
    private var loudSince: TimeInterval?
    /// Timestamp of the last barge-in, and how long after it the engine is held open (see
    /// `isCapturingUtterance`) to let recognition warm up before lazy teardown can win.
    private var lastBargeIn: TimeInterval = 0
    private let bargeInGrace: TimeInterval = 2.5

    // Playback continuation + amplitude (mirrors AudioPlayerService).
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var amplitudeFrames: [Float] = []
    private var amplitudeFrameDuration: TimeInterval = 0
    private var playbackStartTime: TimeInterval = 0
    private var amplitudeTimer: Timer?

    private let locale: Locale

    init(locale: Locale = Locale(identifier: "zh-Hant-TW")) {
        self.locale = locale
    }

    // MARK: - Lifecycle

    /// Start the VPIO engine + continuous recognition. Idempotent.
    func start() async throws {
        guard !isRunning else { return }
        try await ensureAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw STTError.notAvailable
        }
        self.recognizer = recognizer

        // Start the shared VPIO engine; the tap feeds recognition + drives the RMS gate.
        let fmt = try capture.start(onRMS: { [weak self] rms in
            Task { @MainActor in self?.handleMicRMS(rms) }
        })
        playbackFormat = fmt
        isRunning = true

        startRecognition()
        Log.pipeline("[FullDuplex] started (onDevice=\(recognizer.supportsOnDeviceRecognition))")
    }

    /// Stop everything and release the mic/engine.
    func stop() {
        isRunning = false
        invalidateSilenceTimer()
        stopAmplitudeTimer()
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        capture.setRequest(nil)
        capture.stop()
        finishPlayback()
        isSpeaking = false
        currentAmplitude = 0
        Log.pipeline("[FullDuplex] stopped")
    }

    // MARK: - Playback (through the VPIO engine)

    /// Decode + play one audio segment through the VPIO engine, returning when it finishes.
    /// `currentAmplitude` drives lip-sync. Barge-in cuts this off early.
    func play(_ data: Data) async throws {
        // Throw (don't silently return) so the pipeline can't race through segments as if they
        // played when the engine is unexpectedly down.
        guard isRunning, let playbackFormat else {
            throw AudioPlayerError.playbackFailed("full-duplex engine not running")
        }

        // Decode to PCM and convert to the engine's playback format (48k).
        let pcm = try decodeToPCM(data: data, target: playbackFormat)

        amplitudeFrames = Self.precomputeAmplitudes(from: pcm, windowSize: 1024)
        amplitudeFrameDuration = Double(1024) / pcm.format.sampleRate

        finishPlayback() // clear any prior continuation
        isSpeaking = true
        // Recognition keeps running (on echo-cancelled mono) while she speaks — results are
        // ignored, but the audio is fed continuously so a barge-in's words are captured even
        // before the RMS gate stops her, and surface the moment isSpeaking flips false.

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.playbackContinuation = cont
            capture.player.scheduleBuffer(pcm) { [weak self] in
                Task { @MainActor in
                    guard let self, let c = self.playbackContinuation else { return }
                    self.playbackContinuation = nil
                    self.isSpeaking = false
                    self.stopAmplitudeTimer()
                    c.resume()
                }
            }
            if !capture.player.isPlaying { capture.player.play() }
            self.playbackStartTime = CACurrentMediaTime()
            self.startAmplitudeTimer()
        }
    }

    /// Immediately stop playback (used on barge-in / cancel), resolving any pending `play`.
    func stopPlayback() {
        capture.player.stop()
        stopAmplitudeTimer()
        isSpeaking = false // recognition is already running; results now flow (captures barge-in)
        currentAmplitude = 0
        finishPlayback()
    }

    private func finishPlayback() {
        let c = playbackContinuation
        playbackContinuation = nil
        c?.resume()
    }

    // MARK: - Barge-in (RMS gate)

    private func handleMicRMS(_ rms: Float) {
        guard isRunning, isSpeaking else { loudSince = nil; return }
        let now = CACurrentMediaTime()
        if rms >= bargeInRMSThreshold {
            if let since = loudSince {
                if now - since >= bargeInSustain {
                    loudSince = nil
                    lastBargeIn = now // hold the engine open through recognition warm-up
                    Log.pipeline("[FullDuplex] barge-in")
                    stopPlayback()
                    onBargeIn?()
                }
            } else {
                loudSince = now
            }
        } else {
            loudSince = nil
        }
    }

    // MARK: - Continuous recognition

    /// Start listening for a user utterance. Only runs while she is NOT speaking; the RMS gate
    /// (independent of this) handles barge-in during her speech. Idempotent.
    private func startRecognition() {
        // Runs continuously (even while she speaks) so barge-in audio is always captured.
        guard isRunning, recognitionTask == nil, let recognizer else { return }

        recognitionGen &+= 1
        let gen = recognitionGen
        currentUtterance = ""
        invalidateSilenceTimer()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        capture.setRequest(req) // the off-main tap now feeds this request

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                // Ignore callbacks from a superseded task (gen guard) — e.g. the cancellation
                // error raised when `stopRecognition()` tears this task down.
                guard let self, self.isRunning, gen == self.recognitionGen else { return }

                if let result {
                    // Accept transcription only when she is NOT speaking (idle capture, or
                    // post-barge-in). Because audio is fed continuously, a barge-in's words —
                    // spoken before the RMS gate stops her — are already in the recognizer and
                    // surface as soon as isSpeaking flips false.
                    if !self.isSpeaking {
                        let text = result.bestTranscription.formattedString
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.currentUtterance = text
                            self.resetSilenceTimer()
                        }
                    }
                    if result.isFinal { self.finalizeUtterance() }
                    return
                }
                if error != nil { self.finalizeUtterance() }
            }
        }
    }

    /// Tear down the current recognition task + request. Reused on `stop()` and between utterances.
    private func stopRecognition() {
        recognitionGen &+= 1 // invalidate the cancelling task's trailing callbacks
        invalidateSilenceTimer()
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        capture.setRequest(nil)
        currentUtterance = ""
    }

    /// Deliver any captured utterance as a turn, then re-arm a fresh recognition cycle.
    private func finalizeUtterance() {
        guard isRunning else { return } // ignore a silence-timer callback that lands after stop()
        let text = currentUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasSpeaking = isSpeaking
        stopRecognition() // cancel + endAudio the finishing task (else it lingers) and clear state
        if !text.isEmpty && !wasSpeaking {
            onUserUtterance?(text)
        }
        startRecognition() // re-arm for the next utterance
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: utteranceSilence, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finalizeUtterance() }
        }
    }

    private func invalidateSilenceTimer() {
        silenceTimer?.invalidate(); silenceTimer = nil
    }

    // MARK: - Authorization (mirrors STTService)

    private func ensureAuthorization() async throws {
        let micGranted: Bool
        if #available(macOS 14.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
        }
        guard micGranted else { throw STTError.notAuthorized }

        let status = SFSpeechRecognizer.authorizationStatus()
        let speech: SFSpeechRecognizerAuthorizationStatus
        if status == .notDetermined {
            speech = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async {
                    SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
                }
            }
        } else {
            speech = status
        }
        guard speech == .authorized else { throw STTError.notAuthorized }
    }

    // MARK: - Amplitude (lip-sync, ported from AudioPlayerService)

    private func startAmplitudeTimer() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickAmplitude() }
        }
    }

    private func stopAmplitudeTimer() {
        amplitudeTimer?.invalidate(); amplitudeTimer = nil
        amplitudeFrames = []; currentAmplitude = 0
    }

    private func tickAmplitude() {
        guard amplitudeFrameDuration > 0 else { return }
        let idx = Int((CACurrentMediaTime() - playbackStartTime) / amplitudeFrameDuration)
        currentAmplitude = (idx >= 0 && idx < amplitudeFrames.count) ? amplitudeFrames[idx] : 0
    }

    private nonisolated static func precomputeAmplitudes(from buffer: AVAudioPCMBuffer, windowSize: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        let samples = channelData[0]
        var out: [Float] = []; out.reserveCapacity(frameLength / windowSize + 1)
        var offset = 0
        while offset < frameLength {
            let end = min(offset + windowSize, frameLength)
            var sum: Float = 0
            for i in offset..<end { let s = samples[i]; sum += s * s }
            out.append(min(sqrtf(sum / Float(end - offset)) * 5.0, 1.0))
            offset += windowSize
        }
        return out
    }

    // MARK: - Decode (Data -> PCM in target format)

    private nonisolated func decodeToPCM(data: Data, target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let ext: String = {
            if data.count >= 12, data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
               data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 { return "wav" }
            return "mp3"
        }()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let srcFrames = AVAudioFrameCount(file.length)
        guard srcFrames > 0 else { throw AudioPlayerError.decodingFailed("no frames") }
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcFrames) else {
            throw AudioPlayerError.decodingFailed("alloc src")
        }
        try file.read(into: srcBuf)

        // Fast path: already the target format.
        if file.processingFormat == target { return srcBuf }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioPlayerError.decodingFailed("no converter")
        }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(srcFrames) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioPlayerError.decodingFailed("alloc out")
        }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return srcBuf
        }
        if let err { throw AudioPlayerError.decodingFailed(err.localizedDescription) }
        return outBuf
    }
}

// MARK: - VPIO engine + tap (non-isolated, keeps the tap off the main actor)

/// Owns the Voice-Processing `AVAudioEngine`, its player node, and the mic tap. Kept outside
/// `@MainActor` so the real-time tap callback doesn't inherit main-actor isolation (the Swift-6
/// AVFAudio crash — same reason as `STTAudioCapture`).
private final class DuplexCapture: @unchecked Sendable {

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Swap the recognition request the tap feeds (called on the main actor; read on the tap thread).
    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }

    /// Start the engine with voice processing on. Returns the fixed playback format (engine rate, mono).
    func start(onRMS: @escaping @Sendable (Float) -> Void) throws -> AVAudioFormat {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)

        let output = engine.outputNode
        let outFmt = output.inputFormat(forBus: 0) // VPIO hardware rate (e.g. 48k, 2ch)

        // Pin the whole output chain to the VPIO rate, else outputNode init fails (-10875).
        engine.attach(player)
        engine.connect(engine.mainMixerNode, to: output, format: outFmt)
        let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outFmt.sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let inFmt = input.outputFormat(forBus: 0)
        Log.pipeline("[FullDuplex] VPIO input: \(inFmt.channelCount)ch \(inFmt.sampleRate)Hz")

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self, lock] buffer, _ in
            guard let self else { return }
            // VPIO delivers a multi-channel input buffer (e.g. 9ch mic array). SFSpeechRecognizer
            // and our RMS gate need MONO, so extract channel 0 (the echo-cancelled voice channel).
            guard let mono = DuplexCapture.makeMono(from: buffer) else { return }

            lock.lock(); let req = self.request; lock.unlock()
            req?.append(mono)

            if let ch = mono.floatChannelData {
                let n = Int(mono.frameLength)
                if n > 0 {
                    var sum: Float = 0
                    for i in 0..<n { let v = ch[0][i]; sum += v * v }
                    onRMS((sum / Float(n)).squareRoot())
                }
            }
        }

        engine.prepare()
        try engine.start()
        return playbackFormat
    }

    /// Extract channel 0 of a (possibly multi-channel VPIO) buffer as a fresh mono buffer.
    static func makeMono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData else { return nil }
        let frames = buffer.frameLength
        guard frames > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: buffer.format.sampleRate,
                                      channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        out.frameLength = frames
        memcpy(out.floatChannelData![0], src[0], Int(frames) * MemoryLayout<Float>.size)
        return out
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
    }
}

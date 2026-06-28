import Foundation
// @preconcurrency: AVFAudio's AVAudioConverterInputBlock is @Sendable but we capture a
// non-Sendable AVAudioPCMBuffer in it (safe here — the conversion is synchronous). This
// downgrades AVFAudio's Sendable diagnostics to keep the build warning-free under Swift 6.
@preconcurrency import AVFoundation
import Combine
import QuartzCore

// MARK: - Errors

enum AudioPlayerError: LocalizedError {
    case decodingFailed(String)
    case playbackFailed(String)
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .decodingFailed(let detail):
            return "Failed to decode audio data: \(detail)"
        case .playbackFailed(let detail):
            return "Audio playback failed: \(detail)"
        case .engineError(let detail):
            return "Audio engine error: \(detail)"
        }
    }
}

// MARK: - Implementation

@MainActor
final class AudioPlayerService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentAmplitude: Float = 0.0

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackContinuation: CheckedContinuation<Void, Error>?

    /// Pre-computed RMS amplitude values for the current audio segment.
    private var amplitudeFrames: [Float] = []

    /// How many seconds each amplitude frame represents.
    private var amplitudeFrameDuration: TimeInterval = 0

    /// When playback started (CACurrentMediaTime).
    private var playbackStartTime: TimeInterval = 0

    /// Timer driving amplitude updates during playback.
    private var amplitudeTimer: Timer?

    // MARK: - Public Methods

    /// Decodes MP3 `Data` to PCM, plays it through the audio engine, and returns
    /// when playback completes. `currentAmplitude` is updated in real-time for lip sync.
    func playAudioData(_ data: Data) async throws {

        // Stop any existing playback (but keep the engine if possible).
        stopPlayback()

        // Decode MP3 data to PCM buffer.
        let pcmBuffer = try decodeToPCM(data: data)

        // Pre-compute amplitude values for lip sync (avoids AVAudioEngine tap issues).
        let windowSize = 1024
        amplitudeFrames = Self.precomputeAmplitudes(from: pcmBuffer, windowSize: windowSize)
        amplitudeFrameDuration = Double(windowSize) / pcmBuffer.format.sampleRate

        // Reuse or create the audio engine and player node.
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode

        if let existingEngine = audioEngine, let existingPlayer = playerNode, existingEngine.isRunning {
            engine = existingEngine
            player = existingPlayer
            // Reconnect with the new buffer's format in case it changed.
            engine.connect(player, to: engine.mainMixerNode, format: pcmBuffer.format)
        } else {
            // Tear down any stale engine before creating a new one.
            tearDown()

            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            engine.attach(player)

            // Connect player to the mixer. The engine handles format conversion internally.
            engine.connect(player, to: engine.mainMixerNode, format: pcmBuffer.format)

            self.audioEngine = engine
            self.playerNode = player

            // Start the engine.
            engine.prepare()
            do {
                try engine.start()
            } catch {
                tearDown()
                throw AudioPlayerError.engineError(error.localizedDescription)
            }

            // Give the audio IO one cycle to stabilize before playing.
            try await Task.sleep(for: .milliseconds(50))
        }

        isPlaying = true

        // Schedule the buffer and wait for playback to complete.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.playbackContinuation = continuation

            player.scheduleBuffer(pcmBuffer) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // Only resume if this continuation is still active (not cancelled by stop()).
                    if let cont = self.playbackContinuation {
                        self.playbackContinuation = nil
                        self.isPlaying = false
                        self.stopAmplitudeTimer()
                        cont.resume()
                    }
                }
            }

            do {
                try ObjC.catchException {
                    player.play()
                }
            } catch {
                self.playbackContinuation = nil
                self.tearDown()
                continuation.resume(throwing: AudioPlayerError.playbackFailed(error.localizedDescription))
                return
            }

            // Start amplitude timer for lip sync after playback begins.
            self.playbackStartTime = CACurrentMediaTime()
            self.startAmplitudeTimer()
        }
    }

    /// Stops playback immediately and tears down the engine completely.
    func stop() {
        // Capture and clear the continuation before tearDown to avoid double-resume.
        let continuation = playbackContinuation
        playbackContinuation = nil
        tearDown()
        continuation?.resume()
    }

    /// Stops the current playback but keeps the engine running for the next segment.
    private func stopPlayback() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        amplitudeFrames = []

        playerNode?.stop()

        let continuation = playbackContinuation
        playbackContinuation = nil
        continuation?.resume()

        isPlaying = false
        currentAmplitude = 0.0
    }

    // MARK: - Audio Decoding

    /// Decodes MP3 `Data` into a PCM `AVAudioPCMBuffer`.
    private nonisolated func decodeToPCM(data: Data) throws -> AVAudioPCMBuffer {
        // Write data to a temporary file so AVAudioFile can read it.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")

        do {
            try data.write(to: tempURL)
        } catch {
            throw AudioPlayerError.decodingFailed("Failed to write temporary MP3 file: \(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Open the MP3 file.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: tempURL)
        } catch {
            throw AudioPlayerError.decodingFailed("Failed to read MP3 data: \(error.localizedDescription)")
        }

        // Read all frames into a PCM buffer.
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else {
            throw AudioPlayerError.decodingFailed("Audio file contains no frames.")
        }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioFile.processingFormat.sampleRate,
            channels: audioFile.processingFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioPlayerError.decodingFailed("Failed to create PCM output format.")
        }

        // If the source format matches our target, read directly.
        if audioFile.processingFormat.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                throw AudioPlayerError.decodingFailed("Failed to allocate PCM buffer.")
            }
            do {
                try audioFile.read(into: buffer)
            } catch {
                throw AudioPlayerError.decodingFailed("Failed to read audio frames: \(error.localizedDescription)")
            }
            return buffer
        }

        // Otherwise, convert to float32 PCM.
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: pcmFormat) else {
            throw AudioPlayerError.decodingFailed("Failed to create audio converter from \(audioFile.processingFormat) to \(pcmFormat).")
        }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw AudioPlayerError.decodingFailed("Failed to allocate output PCM buffer.")
        }

        // Read the source file into a temporary input buffer.
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw AudioPlayerError.decodingFailed("Failed to allocate input PCM buffer.")
        }

        do {
            try audioFile.read(into: inputBuffer)
        } catch {
            throw AudioPlayerError.decodingFailed("Failed to read audio frames for conversion: \(error.localizedDescription)")
        }

        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw AudioPlayerError.decodingFailed("Audio conversion failed: \(conversionError.localizedDescription)")
        }

        return outputBuffer
    }

    // MARK: - Amplitude Analysis (Pre-computed)

    /// Pre-computes RMS amplitude values from a PCM buffer in fixed-size windows.
    ///
    /// This approach avoids AVAudioEngine tap crashes caused by format mismatches
    /// when the engine converts between input format (e.g. 1ch 32kHz from TTS) and
    /// output format (e.g. 2ch 44.1kHz hardware). Instead, we compute amplitudes
    /// directly from the decoded PCM data and play them back via a timer.
    private nonisolated static func precomputeAmplitudes(from buffer: AVAudioPCMBuffer, windowSize: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        let samples = channelData[0]
        var amplitudes: [Float] = []
        amplitudes.reserveCapacity(frameLength / windowSize + 1)

        var offset = 0
        while offset < frameLength {
            let end = min(offset + windowSize, frameLength)
            var sumOfSquares: Float = 0.0

            for i in offset..<end {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }

            let count = Float(end - offset)
            let rms = sqrtf(sumOfSquares / count)

            // Scale RMS to a 0-1 range. Typical speech RMS is around 0.01-0.15.
            // A multiplier of 5 maps that to roughly 0.05-0.75, which works well for lip sync.
            let scaled = min(rms * 5.0, 1.0)
            amplitudes.append(scaled)

            offset += windowSize
        }

        return amplitudes
    }

    /// Stops the amplitude timer without tearing down the engine.
    private func stopAmplitudeTimer() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        amplitudeFrames = []
        currentAmplitude = 0.0
    }

    /// Starts a timer that drives `currentAmplitude` from the pre-computed values.
    private func startAmplitudeTimer() {
        amplitudeTimer?.invalidate()
        // Update at ~30fps — sufficient for smooth lip sync animation.
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickAmplitude()
            }
        }
    }

    /// Reads the current amplitude from pre-computed values based on elapsed playback time.
    private func tickAmplitude() {
        let elapsed = CACurrentMediaTime() - playbackStartTime
        guard amplitudeFrameDuration > 0 else { return }

        let index = Int(elapsed / amplitudeFrameDuration)
        if index < amplitudeFrames.count {
            currentAmplitude = amplitudeFrames[index]
        } else {
            currentAmplitude = 0
        }
    }

    // MARK: - Cleanup

    private func tearDown() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        amplitudeFrames = []

        playerNode?.stop()
        playerNode = nil

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        audioEngine = nil

        isPlaying = false
        currentAmplitude = 0.0
    }
}

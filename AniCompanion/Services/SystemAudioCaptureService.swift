import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// MARK: - SystemAudioCaptureError

enum SystemAudioCaptureError: LocalizedError {
    case notAuthorized
    case noDisplay
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "Screen Recording permission isn't granted. Enable it in System Settings → Privacy & Security → Screen Recording.")
        case .noDisplay:
            return String(localized: "No display found to capture audio from.")
        case .captureFailed(let detail):
            return String(localized: "System audio capture failed: \(detail)")
        }
    }
}

// MARK: - SystemAudioCaptureService

/// Captures the Mac's **system audio output** (whatever is playing — a video, a call, a podcast)
/// as a stream of PCM buffers, for live transcription.
///
/// Parallels `ScreenVisionService`: same framework (ScreenCaptureKit) and the same macOS
/// **Screen Recording** permission — but where vision takes an on-demand screenshot, this runs a
/// continuous `SCStream` with `capturesAudio` on and no video output attached.
///
/// AniCompanion's own audio (小光's TTS voice) is excluded via `excludesCurrentProcessAudio`, so
/// live transcription never re-captures her own speech (the self-transcription feedback loop).
@MainActor
final class SystemAudioCaptureService {

    /// Whether a capture stream is currently running.
    private(set) var isCapturing = false

    /// Fired (on the main actor) if the stream dies underneath us — e.g. permission revoked
    /// mid-session — so the owner can surface the error and reset its state.
    var onStreamStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private var output: AudioStreamOutput?

    // MARK: - Permission (same TCC grant as ScreenVisionService)

    /// Whether Screen Recording permission is currently granted (does not prompt).
    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Requests Screen Recording permission, prompting the system dialog the first time.
    @discardableResult
    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

    /// Start capturing system audio. `onBuffer` is invoked on a background queue with mono
    /// PCM buffers (48 kHz float) until `stop()` is called.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        guard !isCapturing else { return }
        guard hasAccess else { throw SystemAudioCaptureError.notAuthorized }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // A revoked permission surfaces here as a capture error.
            throw SystemAudioCaptureError.notAuthorized
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        // Audio from the whole system; the display filter is required by SCStream but we never
        // attach a video output, so no frames are rendered.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // never hear 小光's own voice
        config.sampleRate = 48_000
        config.channelCount = 1
        // Minimal video config — no .screen output is added, this just keeps SCK's video path idle.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = AudioStreamOutput(onBuffer: onBuffer, onStopped: { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                self.isCapturing = false
                self.stream = nil
                self.output = nil
                Log.pipeline("[SystemAudio] Stream stopped unexpectedly: \(error?.localizedDescription ?? "no error")")
                self.onStreamStopped?(error)
            }
        })

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioCaptureError.captureFailed(error.localizedDescription)
        }

        self.stream = stream
        self.output = output
        isCapturing = true
        Log.pipeline("[SystemAudio] Capture started (48 kHz mono, own audio excluded)")
    }

    /// Stop capturing. Safe to call when not running.
    func stop() async {
        guard isCapturing, let stream else {
            isCapturing = false
            return
        }
        isCapturing = false
        self.stream = nil
        self.output = nil
        do {
            try await stream.stopCapture()
        } catch {
            // Already-stopped streams throw; nothing to do.
            Log.pipeline("[SystemAudio] stopCapture: \(error.localizedDescription)")
        }
        Log.pipeline("[SystemAudio] Capture stopped")
    }
}

// MARK: - AudioStreamOutput (non-isolated SCK callback target)

/// Receives `SCStream` audio sample buffers on a background queue and forwards them as
/// `AVAudioPCMBuffer`s. Kept outside `@MainActor` (same reason as `STTAudioCapture`): the
/// sample-handler callbacks must not inherit main-actor isolation.
private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    let queue = DispatchQueue(label: "com.anicompanion.system-audio-capture")

    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStopped: @Sendable (Error?) -> Void

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onStopped: @escaping @Sendable (Error?) -> Void) {
        self.onBuffer = onBuffer
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error)
    }

    /// Deep-copy a CMSampleBuffer's PCM data into a standalone AVAudioPCMBuffer (the sample
    /// buffer's backing memory is only valid for the duration of the callback), downmixed to mono.
    ///
    /// `channelCount = 1` on the stream config is only a *hint* — SCK often delivers stereo anyway.
    /// The macOS-15 `SFSpeechRecognizer` path needs mono (a multi-channel buffer yields a permanent
    /// "no speech" err 1110, the same trap documented for VPIO), so we guarantee mono here.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer.format.channelCount > 1 ? (downmixToMono(buffer) ?? buffer) : buffer
    }

    /// Average a multi-channel (deinterleaved float) buffer into a fresh mono buffer. Returns the
    /// original untouched for any layout we can't fold (e.g. interleaved/integer) — best effort.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1, let src = buffer.floatChannelData else { return buffer }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: buffer.format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity) else {
            return buffer
        }
        mono.frameLength = buffer.frameLength
        let dst = mono.floatChannelData![0]
        let frames = Int(buffer.frameLength)
        let scale = 1.0 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += src[c][f] }
            dst[f] = sum * scale
        }
        return mono
    }
}

import Foundation
import Speech
import AVFoundation

// MARK: - Errors

enum STTError: LocalizedError {
    case notAuthorized
    case notAvailable
    case recognitionFailed(String)
    case audioEngineError(String)
    case dictationDisabled

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "Speech recognition or microphone access isn't granted. Open System Settings → Privacy & Security to enable it.")
        case .notAvailable:
            return String(localized: "Speech recognition isn't supported for the current language.")
        case .recognitionFailed(let detail):
            return String(localized: "Speech recognition failed: \(detail)")
        case .audioEngineError(let detail):
            return String(localized: "Audio engine error: \(detail)")
        case .dictationDisabled:
            return String(localized: "Please enable Dictation first: System Settings → Keyboard → Dictation → On.")
        }
    }
}

// MARK: - Protocol

@MainActor
protocol STTServiceProtocol {
    func startListening(locale: Locale) -> AsyncThrowingStream<String, Error>
    func stopListening()
    var isListening: Bool { get }
}

// MARK: - Audio Capture Helper

/// Non-isolated helper that manages AVAudioEngine + tap.
/// Kept outside @MainActor to avoid Swift 6 actor isolation on the audio tap callback.
private final class STTAudioCapture: @unchecked Sendable {

    private var engine: AVAudioEngine?

    func start(request: SFSpeechAudioBufferRecognitionRequest) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        self.engine = engine

        Log.stt("[STT] Accessing inputNode...")
        let inputNode = engine.inputNode
        Log.stt("[STT] Getting recording format...")
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        Log.stt("[STT] Recording format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

        guard recordingFormat.sampleRate > 0 else {
            throw STTError.audioEngineError("No valid audio input format available. Check microphone connection.")
        }

        // Install tap — this closure runs on a real-time audio thread.
        // Because this class is NOT @MainActor, the closure won't inherit main actor isolation.
        Log.stt("[STT] Installing tap on inputNode...")
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            request.append(buffer)
        }

        // Start the audio engine.
        Log.stt("[STT] Preparing and starting audio engine...")
        engine.prepare()
        try engine.start()
        Log.stt("[STT] Audio engine started successfully")

        return engine
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        engine = nil
    }
}

// MARK: - Implementation

@MainActor
final class STTService: STTServiceProtocol {

    // MARK: - Public State

    private(set) var isListening: Bool = false

    // MARK: - Private Properties

    private let audioCapture = STTAudioCapture()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var silenceTimer: Timer?

    /// Whether any non-empty speech has been transcribed in the current session.
    /// Controls which timeout the silence timer uses.
    private var hasDetectedSpeech: Bool = false

    /// Seconds to wait for the user to *start* speaking before auto-stopping.
    /// More generous than `silenceTimeout` so opening the mic and taking a beat
    /// before talking doesn't immediately end the session.
    private let initialSpeechTimeout: TimeInterval = 5.0

    /// Seconds of silence *after* speech has begun before auto-stopping recognition.
    private let silenceTimeout: TimeInterval = 2.0

    /// Default locale for Traditional Chinese.
    private let defaultLocale = Locale(identifier: "zh-Hant-TW")

    // MARK: - Public Methods

    func startListening(locale: Locale) -> AsyncThrowingStream<String, Error> {
        let targetLocale = locale
        Log.stt("[STT] startListening called, locale=\(targetLocale.identifier)")

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    Log.stt("[STT] Requesting authorization...")
                    try await self.ensureAuthorization()
                    Log.stt("[STT] Authorization granted, waiting for system to settle...")
                    try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                    Log.stt("[STT] Beginning recognition...")
                    try self.beginRecognition(locale: targetLocale, continuation: continuation)
                    Log.stt("[STT] Recognition started successfully")
                } catch is CancellationError {
                    Log.stt("[STT] Cancelled during startup")
                    self.tearDown()
                    continuation.finish()
                } catch {
                    Log.stt("[STT] Error during startup: \(error)")
                    self.tearDown()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.tearDown()
                }
                task.cancel()
            }
        }
    }

    func stopListening() {
        tearDown()
    }

    // MARK: - Authorization

    private func ensureAuthorization() async throws {
        // Request microphone permission first (this works reliably).
        Log.stt("[STT] Requesting microphone permission...")
        let micGranted: Bool
        if #available(macOS 14.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        Log.stt("[STT] Microphone granted: \(micGranted)")

        guard micGranted else {
            throw STTError.notAuthorized
        }

        // Request speech recognition authorization from a background queue
        // to avoid crashes when called from Swift async/MainActor context.
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        Log.stt("[STT] Current speech recognition status: \(currentStatus.rawValue)")

        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if currentStatus == .notDetermined {
            Log.stt("[STT] Requesting speech recognition authorization (via GCD)...")
            speechStatus = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    SFSpeechRecognizer.requestAuthorization { status in
                        Log.stt("[STT] Speech auth callback: \(status.rawValue)")
                        cont.resume(returning: status)
                    }
                }
            }
            Log.stt("[STT] Speech authorization result: \(speechStatus.rawValue)")
        } else {
            speechStatus = currentStatus
        }

        guard speechStatus == .authorized else {
            throw STTError.notAuthorized
        }
    }

    // MARK: - Recognition

    private func beginRecognition(
        locale: Locale,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        // Tear down any previous session.
        Log.stt("[STT] Tearing down previous session...")
        tearDown()

        // Initialize recognizer for the target locale.
        Log.stt("[STT] Creating SFSpeechRecognizer for locale: \(locale.identifier)")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw STTError.notAvailable
        }
        self.speechRecognizer = recognizer
        Log.stt("[STT] SFSpeechRecognizer created, onDevice=\(recognizer.supportsOnDeviceRecognition)")

        // Create the recognition request.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device recognition when the locale supports it: no network, private, and
        // (crucially for hands-free continuous listening) not subject to server rate limits.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        // Start audio capture via the non-isolated helper (avoids Swift 6 actor isolation crash).
        Log.stt("[STT] Starting audio capture...")
        do {
            _ = try audioCapture.start(request: request)
        } catch {
            Log.stt("[STT] Audio capture start failed: \(error)")
            tearDown()
            throw error
        }

        // Start the recognition task.
        Log.stt("[STT] Starting recognition task...")
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Log.stt("[STT] Recognition callback: result=\(result != nil), error=\(String(describing: error))")
            Task { @MainActor in
                guard let self else {
                    Log.stt("[STT] Recognition callback: self is nil, ignoring")
                    return
                }

                if let result {
                    let transcription = result.bestTranscription.formattedString
                    Log.stt("[STT] Transcription received (final=\(result.isFinal), \(transcription.count) chars)")
                    // Only yield non-empty transcriptions to avoid overwriting
                    // good partial results with an empty final result.
                    if !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(transcription)
                        // Speech has begun — switch to the shorter inter-word timeout.
                        self.hasDetectedSpeech = true
                        // Reset silence timer — user is still speaking.
                        self.resetSilenceTimer()
                    }

                    if result.isFinal {
                        self.invalidateSilenceTimer()
                        self.tearDown()
                        continuation.finish()
                    }
                }

                if let error {
                    let nsError = error as NSError
                    let desc = nsError.localizedDescription.lowercased()
                    Log.stt("[STT] Recognition error: domain=\(nsError.domain), code=\(nsError.code), desc=\(nsError.localizedDescription)")

                    // Detect cancellation — can come from multiple domains.
                    let isCancellation =
                        (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216) ||
                        (nsError.domain == "kLSRErrorDomain" && nsError.code == 301) ||
                        desc.contains("cancel")

                    // "No speech detected" is benign — the mic opened but nothing was said
                    // before the silence timer auto-stopped. Finish quietly instead of
                    // surfacing an error banner.
                    let isNoSpeech =
                        (nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 203)) ||
                        desc.contains("no speech")

                    if isCancellation || isNoSpeech {
                        // Graceful end — finish the stream so the caller gets the last
                        // partial transcription (if any), with no error.
                        Log.stt("[STT] Recognition ended gracefully (cancelled or no speech)")
                        self.tearDown()
                        continuation.finish()
                    } else if desc.contains("dictation") || desc.contains("siri") {
                        // "Siri and Dictation are disabled" error.
                        self.tearDown()
                        continuation.finish(throwing: STTError.dictationDisabled)
                    } else {
                        self.tearDown()
                        continuation.finish(throwing: STTError.recognitionFailed(error.localizedDescription))
                    }
                }
            }
        }
        Log.stt("[STT] Recognition task created")
        self.recognitionTask = task
        self.isListening = true
        // Start the silence timer — if no speech is detected within the timeout, auto-stop.
        resetSilenceTimer()
    }

    // MARK: - Silence Timer

    /// Reset the silence timer. Called each time a non-empty partial result arrives.
    /// When the timer fires (no new speech for `silenceTimeout` seconds), recognition stops automatically.
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        // Use a longer window before the first word; tighten up once speech begins.
        let interval = hasDetectedSpeech ? silenceTimeout : initialSpeechTimeout
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                Log.stt("[STT] Silence timeout (\(interval)s) — auto-stopping recognition")
                self.stopListening()
            }
        }
    }

    private func invalidateSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Cleanup

    private func tearDown() {
        invalidateSilenceTimer()

        audioCapture.stop()

        // End the recognition request so the task receives a final result.
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Cancel any in-flight recognition task.
        recognitionTask?.cancel()
        recognitionTask = nil

        speechRecognizer = nil
        isListening = false
        hasDetectedSpeech = false
    }
}

import Foundation
import SwiftUI
import Speech
import Translation
// @preconcurrency: engine `feed` paths handle AVAudioPCMBuffer inside @Sendable callbacks
// (safe — each buffer is a fresh copy owned by the callback). Same pattern as FullDuplexVoiceService.
@preconcurrency import AVFoundation

// MARK: - LiveCaptionSourceLanguage

/// The source language being transcribed (independent of the app/UI language — you watch a
/// Japanese video while the app runs in Traditional Chinese).
enum LiveCaptionSourceLanguage: String, CaseIterable, Identifiable, Sendable {
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case mandarinTaiwan = "zh-TW"
    case english = "en-US"

    var id: String { rawValue }

    static let storageKey = "live_transcription_source_lang"

    /// Endonym + English, so the label is recognizable regardless of UI language.
    var displayName: String {
        switch self {
        case .japanese:       return "日本語 (Japanese)"
        case .korean:         return "한국어 (Korean)"
        case .mandarinTaiwan: return "中文（台灣）(Mandarin)"
        case .english:        return "English (US)"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Bare language for the Translation framework (ja-JP → ja).
    var translationSource: Locale.Language {
        Locale.Language(identifier: Locale(identifier: rawValue).language.languageCode?.identifier ?? rawValue)
    }
}

// MARK: - LiveCaptionTargetLanguage

/// The language captions are translated *into* (Phase 2). Endonym labels — recognizable
/// regardless of UI language, like `LiveCaptionSourceLanguage`.
enum LiveCaptionTargetLanguage: String, CaseIterable, Identifiable, Sendable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    static let storageKey = "live_transcription_target_lang"

    var displayName: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese:  return "简体中文"
        case .english:            return "English"
        }
    }

    var language: Locale.Language { Locale.Language(identifier: rawValue) }
}

// MARK: - LiveCaptionModelStatus

/// On-device availability of the speech model for a source language — drives the Settings row.
enum LiveCaptionModelStatus: Equatable, Sendable {
    /// On-device model installed — private, offline, free.
    case installed
    /// Supported on-device (macOS 26+ SpeechTranscriber) after a one-time model download.
    case needsDownload
    /// No on-device path; recognition falls back to Apple's servers (macOS 15 SFSpeechRecognizer).
    case appleServer
    /// This language can't be transcribed on this system.
    case unsupported
}

// MARK: - LiveTranscriptionError

enum LiveTranscriptionError: LocalizedError {
    case languageUnsupported(String)
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .languageUnsupported(let name):
            return String(localized: "Live transcription doesn't support \(name) on this Mac.")
        case .recognizerUnavailable:
            return String(localized: "The speech recognizer is unavailable right now.")
        }
    }
}

// MARK: - CaptionTranslator

/// Translates one finalized caption segment. Seam for the on-device Apple path today and an
/// LLM fallback later (mirrors the `StreamingTranscriptionEngine` seam).
@MainActor
protocol CaptionTranslator: AnyObject {
    func translate(_ text: String) async throws -> String
}

/// Apple Translation framework, fully on-device. The programmatic `TranslationSession`
/// initializer (macOS 26+) requires the language pair's pack to be **already installed**
/// (`LanguageAvailability.status == .installed`) — check before constructing; a missing pack
/// surfaces as a throw on `translate`.
@available(macOS 26.0, *)
@MainActor
private final class AppleCaptionTranslator: CaptionTranslator {

    // nonisolated(unsafe): TranslationSession is not Sendable and `translate` is nonisolated
    // async, so awaiting it "sends" the session out of the main actor. Safe here — the session
    // is only ever used by the controller's single serial translation worker.
    nonisolated(unsafe) private let session: TranslationSession

    init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target)
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}

// MARK: - StreamingTranscriptionEngine

/// A continuous speech-to-text engine fed by external audio buffers (system audio here — not a
/// mic tap). `feed` is called on the capture queue; everything else on the main actor.
/// Sendable so the capture callback can hold the engine (impls are @unchecked, lock-guarded).
protocol StreamingTranscriptionEngine: AnyObject, Sendable {
    /// Start recognition. `onSegment(text, isFinal)` may be called from any thread.
    /// `onDownloadProgress` reports one-time model download progress (0…1, macOS 26 path only).
    @MainActor func start(
        locale: Locale,
        onSegment: @escaping @Sendable (String, Bool) -> Void,
        onDownloadProgress: @escaping @Sendable (Double?) -> Void
    ) async throws

    /// Feed one PCM buffer (called on the capture queue; the buffer is owned by the callee).
    nonisolated func feed(_ buffer: AVAudioPCMBuffer)

    @MainActor func stop() async
}

// MARK: - LiveTranscriptionController

/// Owns the live-transcription loop: system audio (ScreenCaptureKit) → streaming Apple speech
/// recognition (source language) → live captions.
///
/// **Display-only** (Phase 1): captions render in the desktop-pet speech bubble and in the main
/// window's caption overlay — she never *speaks* them (speaking your own transcription back over
/// the video is Phase 3, with capture-gating).
///
/// Engine selection: `SpeechTranscriber` (macOS 26+, on-device, purpose-built for long-form live
/// transcription, per-language model download) with an `SFSpeechRecognizer` fallback (macOS 15,
/// Apple-server-based for languages without on-device support, cycled per utterance).
@MainActor
final class LiveTranscriptionController: ObservableObject {

    // MARK: Published (UI)

    /// Whether capture + recognition are running.
    @Published private(set) var isRunning = false

    /// The current caption line, trimmed for display. Transcribe mode: finalized tail + live
    /// partial of the source speech. Translate mode: the rolling *translated* tail.
    @Published private(set) var captionText: String = ""

    /// Rolling original-language line while translation is active (the live partial keeps
    /// moving here between translated segments); empty in transcribe-only mode.
    @Published private(set) var originalText: String = ""

    /// Whether a translator is actually attached to this session (translate toggle on AND the
    /// language pack was available) — drives the overlay's dual-line layout.
    @Published private(set) var isTranslating = false

    /// One-time speech-model download progress (0…1) while the engine fetches assets; nil otherwise.
    @Published private(set) var modelDownloadProgress: Double?

    /// The most recent start/stream error, for the Settings/overlay UI.
    @Published private(set) var lastError: Error?

    /// Whether the feature is enabled in Settings (mirrors the saved toggle via `apply`).
    /// Distinct from `isRunning`: enabled-but-not-running means starting, downloading the
    /// model, or failed — states the UI must surface instead of silently showing nothing.
    @Published private(set) var isEnabled = false

    // MARK: Wiring (set by AppState)

    /// Renders captions in the desktop-pet speech bubble.
    weak var characterController: (any CharacterControllerProtocol)?

    /// Whether 小光 is currently speaking a reply — her pipeline owns the bubble then, so
    /// captions skip the bubble (the main-window overlay still updates).
    var isCharacterSpeaking: @MainActor () -> Bool = { false }

    // MARK: State

    private let capture = SystemAudioCaptureService()
    private var engine: (any StreamingTranscriptionEngine)?

    /// Finalized text of the utterance in progress (SpeechTranscriber finalizes in chunks).
    private var finalizedTail: String = ""
    /// The live (volatile) partial being refined.
    private var volatileText: String = ""

    /// Hides the caption after audio goes quiet for a while.
    private var idleHideTask: Task<Void, Never>?

    /// Bumped per start so stale segment callbacks from a stopped session are ignored.
    private var sessionGeneration: UInt64 = 0

    /// The locale the current/last session was started with.
    private(set) var sourceLocale: Locale = LiveCaptionSourceLanguage.japanese.locale

    // Translation (Phase 2)

    /// Saved translate settings (mirrored by `apply`).
    private(set) var translateEnabled = false
    private(set) var targetLanguage: LiveCaptionTargetLanguage = .traditionalChinese
    /// Bare source language for the translator (derived from the source language choice).
    private var translationSource: Locale.Language = LiveCaptionSourceLanguage.japanese.translationSource

    private var translator: (any CaptionTranslator)?
    /// Finalized segments awaiting translation, processed strictly in order.
    private var pendingTranslations: [String] = []
    private var translationWorker: Task<Void, Never>?
    /// The rolling translated text (windowed like `finalizedTail`).
    private var translatedTail: String = ""

    /// Longest caption shown at once (the bubble is small; captions read as a rolling tail).
    private let maxCaptionLength = 72

    // MARK: - Permission (delegated to the capture service)

    var hasAccess: Bool { capture.hasAccess }

    @discardableResult
    func requestAccess() -> Bool { capture.requestAccess() }

    // MARK: - Model status (Settings)

    /// On-device model availability for a source language (drives the Settings status row).
    static func modelStatus(for locale: Locale) async -> LiveCaptionModelStatus {
        if #available(macOS 26.0, *) {
            let supported = await SpeechTranscriber.supportedLocales
            let target = locale.identifier(.bcp47)
            if supported.contains(where: { $0.identifier(.bcp47) == target }) {
                let installed = await SpeechTranscriber.installedLocales
                return installed.contains(where: { $0.identifier(.bcp47) == target })
                    ? .installed : .needsDownload
            }
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return .unsupported }
        return recognizer.supportsOnDeviceRecognition ? .installed : .appleServer
    }

    // MARK: - Apply settings

    /// Reconcile the running state with the saved settings (called on launch and on Settings
    /// save). Starts, stops, or restarts (any setting change) as needed.
    func apply(
        enabled: Bool,
        source: LiveCaptionSourceLanguage,
        translate: Bool,
        target: LiveCaptionTargetLanguage
    ) {
        isEnabled = enabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            let changed = source.locale.identifier != self.sourceLocale.identifier
                || translate != self.translateEnabled
                || target != self.targetLanguage
            if self.isRunning, !enabled || changed {
                await self.stop()
            }
            self.sourceLocale = source.locale
            self.translationSource = source.translationSource
            self.translateEnabled = translate
            self.targetLanguage = target
            if enabled, !self.isRunning {
                await self.start()
            }
        }
    }

    // MARK: - Start / Stop

    func start() async {
        guard !isRunning else { return }
        lastError = nil

        guard capture.hasAccess else {
            lastError = SystemAudioCaptureError.notAuthorized
            Log.pipeline("[LiveCaption] Start blocked — Screen Recording permission not granted (preflight false)")
            return
        }

        sessionGeneration &+= 1
        let gen = sessionGeneration
        finalizedTail = ""
        volatileText = ""
        translatedTail = ""
        pendingTranslations = []

        // Attach the translator when asked and the pack is on-device; otherwise degrade to
        // plain transcription (non-fatal — the Settings status row explains why).
        translator = nil
        if translateEnabled {
            translator = await Self.makeTranslator(source: translationSource, target: targetLanguage.language)
            if translator == nil {
                Log.pipeline("[LiveCaption] Translate requested but unavailable (\(translationSource.minimalIdentifier) → \(targetLanguage.rawValue)) — captions stay untranslated")
            }
        }
        isTranslating = translator != nil

        let engine = Self.makeEngine(for: sourceLocale)
        self.engine = engine

        do {
            try await engine.start(
                locale: sourceLocale,
                onSegment: { [weak self] text, isFinal in
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.sessionGeneration else { return }
                        self.handleSegment(text, isFinal: isFinal)
                    }
                },
                onDownloadProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.sessionGeneration else { return }
                        self.modelDownloadProgress = progress
                    }
                }
            )

            capture.onStreamStopped = { [weak self] error in
                guard let self, gen == self.sessionGeneration else { return }
                self.lastError = error
                Task { @MainActor [weak self] in await self?.stop() }
            }
            try await capture.start(onBuffer: { [weak engine] buffer in
                engine?.feed(buffer)
            })

            isRunning = true
            Log.pipeline("[LiveCaption] Started (locale=\(sourceLocale.identifier))")
        } catch {
            lastError = error
            modelDownloadProgress = nil
            await engine.stop()
            self.engine = nil
            Log.pipeline("[LiveCaption] Start failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        sessionGeneration &+= 1 // invalidate in-flight segment callbacks
        idleHideTask?.cancel(); idleHideTask = nil
        translationWorker?.cancel(); translationWorker = nil
        pendingTranslations = []
        translator = nil
        isTranslating = false
        await capture.stop()
        if let engine {
            await engine.stop()
            self.engine = nil
        }
        isRunning = false
        modelDownloadProgress = nil
        captionText = ""
        originalText = ""
        characterController?.setSpeechText(nil)
        Log.pipeline("[LiveCaption] Stopped")
    }

    // MARK: - Caption assembly

    /// Fold a recognition segment into the rolling caption. SpeechTranscriber alternates volatile
    /// partials (refined in place) with finalized chunks; the legacy engine behaves the same via
    /// its per-utterance cycle.
    ///
    /// Transcribe mode: the rolling original IS the caption. Translate mode: the rolling
    /// original goes to the secondary `originalText` line, and each *finalized* segment is
    /// queued for translation (volatile partials churn too much to translate) — the translated
    /// tail becomes the caption when each translation lands.
    private func handleSegment(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !trimmed.isEmpty {
                finalizedTail += trimmed
                if translator != nil { enqueueTranslation(trimmed) }
            }
            volatileText = ""
        } else {
            volatileText = trimmed
        }

        var display = finalizedTail + volatileText
        if display.count > maxCaptionLength {
            display = String(display.suffix(maxCaptionLength))
            // The finalized prefix beyond the window will never be shown again — drop it.
            if finalizedTail.count > maxCaptionLength {
                finalizedTail = String(finalizedTail.suffix(maxCaptionLength))
            }
        }
        guard !display.isEmpty else { return }

        if translator != nil {
            originalText = display
        } else {
            captionText = display
            if !isCharacterSpeaking() {
                characterController?.setSpeechText(display)
            }
        }
        scheduleIdleHide()
    }

    // MARK: - Translation (Phase 2)

    /// Queue a finalized segment and make sure the serial worker is draining — segments must
    /// translate strictly in order or the tail reads shuffled.
    private func enqueueTranslation(_ segment: String) {
        pendingTranslations.append(segment)
        guard translationWorker == nil else { return }
        let gen = sessionGeneration
        translationWorker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, gen == self.sessionGeneration,
                  !self.pendingTranslations.isEmpty {
                let segment = self.pendingTranslations.removeFirst()
                var translated = segment // graceful: a failed segment shows untranslated
                do {
                    if let translator = self.translator {
                        translated = try await translator.translate(segment)
                    }
                } catch {
                    Log.pipeline("[LiveCaption] Translate failed (showing original): \(error.localizedDescription)")
                }
                guard gen == self.sessionGeneration else { break }
                self.appendTranslated(translated)
            }
            self?.translationWorker = nil
        }
    }

    private func appendTranslated(_ text: String) {
        translatedTail += text
        if translatedTail.count > maxCaptionLength {
            translatedTail = String(translatedTail.suffix(maxCaptionLength))
        }
        captionText = translatedTail
        if !isCharacterSpeaking() {
            characterController?.setSpeechText(translatedTail)
        }
        scheduleIdleHide()
    }

    /// Build the on-device translator when the language pack is installed; nil otherwise.
    private static func makeTranslator(source: Locale.Language, target: Locale.Language) async -> (any CaptionTranslator)? {
        guard #available(macOS 26.0, *) else { return nil }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { return nil }
        return AppleCaptionTranslator(source: source, target: target)
    }

    /// Availability of the on-device translation pack for a pair — drives the Settings row.
    static func translationStatus(from source: Locale.Language, to target: Locale.Language) async -> LiveCaptionModelStatus {
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Hide the caption a few seconds after recognition goes quiet (video paused, silence).
    private func scheduleIdleHide() {
        idleHideTask?.cancel()
        idleHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.captionText = ""
            self.originalText = ""
            self.finalizedTail = ""
            self.volatileText = ""
            self.translatedTail = ""
            if !self.isCharacterSpeaking() {
                self.characterController?.setSpeechText(nil)
            }
        }
    }

    // MARK: - Engine selection

    private static func makeEngine(for locale: Locale) -> any StreamingTranscriptionEngine {
        if #available(macOS 26.0, *) {
            return TranscriberEngine()
        }
        return LegacyRecognizerEngine()
    }
}

// MARK: - TranscriberEngine (macOS 26+, SpeechAnalyzer / SpeechTranscriber)

/// Apple's long-form on-device streaming transcriber (the Live Captions engine): no ~1-minute
/// request limit, volatile+finalized results, per-language model managed via `AssetInventory`
/// (downloaded in-app on first use, with progress).
@available(macOS 26.0, *)
private final class TranscriberEngine: StreamingTranscriptionEngine, @unchecked Sendable {

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?

    /// Guards the members the capture-queue `feed` touches.
    private let lock = NSLock()
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // Forced-finalization state (guarded by `lock`; written by the results task, read by the
    // finalize loop). Left alone, the transcriber finalizes lazily — waiting for a long pause —
    // which is what made captions (and especially translations, which only consume *finalized*
    // segments) trail the audio by several seconds.
    private var pendingVolatile = false
    private var lastVolatileText = ""
    private var volatileSince: TimeInterval = 0
    private var volatileStableSince: TimeInterval = 0

    /// Force-finalize once the hypothesis has stopped changing for this long…
    private let stabilityThreshold: TimeInterval = 0.6
    /// …or unconditionally once the oldest unfinalized words are this old (keeps long
    /// uninterrupted speech flowing instead of pooling in one giant volatile segment).
    private let maxVolatileAge: TimeInterval = 2.0

    @MainActor
    func start(
        locale: Locale,
        onSegment: @escaping @Sendable (String, Bool) -> Void,
        onDownloadProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        let target = locale.identifier(.bcp47)
        guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
            throw LiveTranscriptionError.languageUnsupported(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // One-time on-device model download (no-op when already installed).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.pipeline("[LiveCaption] Downloading speech model for \(locale.identifier)…")
            let progress = request.progress
            let poller = Task {
                while !Task.isCancelled {
                    onDownloadProgress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { poller.cancel(); onDownloadProgress(nil) }
            try await request.downloadAndInstall()
            Log.pipeline("[LiveCaption] Speech model installed for \(locale.identifier)")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock {
            self.analyzerFormat = format
            self.inputContinuation = continuation
        }

        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.trackVolatile(text: text, isFinal: result.isFinal)
                    onSegment(text, result.isFinal)
                }
            } catch is CancellationError {
                // Session torn down.
            } catch {
                Log.pipeline("[LiveCaption] Transcriber results ended: \(error.localizedDescription)")
            }
        }

        startFinalizeLoop(analyzer: analyzer)
    }

    // MARK: Forced finalization (latency control)

    /// Record volatile-hypothesis churn so the finalize loop knows when speech has settled.
    private func trackVolatile(text: String, isFinal: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if isFinal {
            pendingVolatile = false
            lastVolatileText = ""
            return
        }
        guard !text.isEmpty else { return }
        if !pendingVolatile {
            pendingVolatile = true
            volatileSince = now
        }
        if text != lastVolatileText {
            lastVolatileText = text
            volatileStableSince = now
        }
    }

    /// Poll for a settled (or stale) hypothesis and ask the analyzer to finalize it, instead of
    /// waiting for the transcriber's own (much later) pause detection. Trades a little accuracy
    /// (no long lookahead) for captions that keep pace with the audio — this is what feeds the
    /// translator promptly, since it only consumes finalized segments.
    private func startFinalizeLoop(analyzer: SpeechAnalyzer) {
        finalizeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let due = self.lock.withLock {
                    let due = self.pendingVolatile
                        && (now - self.volatileStableSince >= self.stabilityThreshold
                            || now - self.volatileSince >= self.maxVolatileAge)
                    if due { self.pendingVolatile = false } // don't re-trigger while finalizing
                    return due
                }
                guard due else { continue }
                do {
                    try await analyzer.finalize(through: nil)
                } catch {
                    Log.pipeline("[LiveCaption] finalize(through:) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let continuation = inputContinuation else { lock.unlock(); return }
        let targetFormat = analyzerFormat

        // Convert to the analyzer's preferred format if it differs. The converter is created
        // once and reused so its resampler state carries across buffer boundaries.
        var outBuffer = buffer
        if let targetFormat, targetFormat != buffer.format {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter else { lock.unlock(); return }
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                lock.unlock(); return
            }
            let feeder = ConverterInput(buffer)
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                guard let next = feeder.take() else { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                return next
            }
            guard error == nil, converted.frameLength > 0 else { lock.unlock(); return }
            outBuffer = converted
        }
        lock.unlock()

        continuation.yield(AnalyzerInput(buffer: outBuffer))
    }

    @MainActor
    func stop() async {
        lock.withLock {
            inputContinuation?.finish()
            inputContinuation = nil
            converter = nil
        }

        finalizeTask?.cancel()
        finalizeTask = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
    }
}

/// Hands a single buffer to `AVAudioConverter`'s @Sendable input block exactly once
/// (the block runs synchronously inside `convert`; the box just satisfies Sendability).
private final class ConverterInput: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { pending = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - LegacyRecognizerEngine (macOS 15, SFSpeechRecognizer)

/// Fallback for pre-26 systems: a continuously re-armed `SFSpeechRecognizer` (the same
/// cycle-per-utterance pattern as `FullDuplexVoiceService`, fed by SCK buffers instead of a mic
/// tap). For languages without on-device support (ja/ko on macOS 15) audio goes to Apple's
/// servers — surfaced in Settings as "Apple servers".
private final class LegacyRecognizerEngine: NSObject, StreamingTranscriptionEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onSegment: (@Sendable (String, Bool) -> Void)?
    private var running = false
    private var generation: UInt64 = 0

    @MainActor
    func start(
        locale: Locale,
        onSegment: @escaping @Sendable (String, Bool) -> Void,
        onDownloadProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        try await Self.ensureSpeechAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LiveTranscriptionError.recognizerUnavailable
        }
        self.recognizer = recognizer
        self.onSegment = onSegment
        running = true
        startCycle()
        Log.pipeline("[LiveCaption] Legacy recognizer started (onDevice=\(recognizer.supportsOnDeviceRecognition))")
    }

    /// One recognition request per utterance/segment, re-armed on `isFinal` or error —
    /// SFSpeechRecognizer caps a single request at about a minute, so cycling is mandatory.
    @MainActor
    private func startCycle() {
        guard running, let recognizer else { return }

        generation &+= 1
        let gen = generation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        lock.lock(); request = req; lock.unlock()

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.running, gen == self.generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.onSegment?(text, result.isFinal)
                    if result.isFinal {
                        self.recycle(delay: .zero)
                    }
                    return
                }
                if error != nil {
                    // Includes benign "no speech" while the source is silent — re-arm with a
                    // short breath so a persistent failure can't spin.
                    self.recycle(delay: .milliseconds(400))
                }
            }
        }
    }

    @MainActor
    private func recycle(delay: Duration) {
        recognitionTask?.cancel()
        recognitionTask = nil
        lock.lock(); request = nil; lock.unlock()
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            self?.startCycle()
        }
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let req = request; lock.unlock()
        req?.append(buffer)
    }

    @MainActor
    func stop() async {
        running = false
        generation &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        lock.withLock {
            request?.endAudio()
            request = nil
        }
        onSegment = nil
    }

    /// Speech-recognition authorization (no mic involved — the audio is system output).
    /// Mirrors `FullDuplexVoiceService`: request off the main actor (the macOS crash gotcha).
    private static func ensureSpeechAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        let resolved: SFSpeechRecognizerAuthorizationStatus
        if status == .notDetermined {
            resolved = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async {
                    SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
                }
            }
        } else {
            resolved = status
        }
        guard resolved == .authorized else { throw STTError.notAuthorized }
    }
}

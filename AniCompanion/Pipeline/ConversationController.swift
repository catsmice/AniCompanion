import Foundation
import Combine

// MARK: - Character Controller Protocol

/// Protocol for controlling the VRM character's expressions and lip sync.
///
/// Implemented by the character rendering layer to respond to emotion changes
/// and audio amplitude for lip sync.
protocol CharacterControllerProtocol: AnyObject, Sendable {
    @MainActor func setExpression(_ emotion: Emotion, blendDuration: TimeInterval)
    @MainActor func setMouthOpen(_ value: Float)
    @MainActor func playIdleAnimation()
    @MainActor func playAnimation(named: String)
    @MainActor func stopAnimation()
}

// MARK: - ConversationController

/// Main orchestrator that ties together chat streaming, sentence parsing, TTS synthesis,
/// and audio playback with character animation.
///
/// This controller manages the full conversation pipeline:
/// 1. User sends a text message (or voice input via STT).
/// 2. The message is sent to the chat backend, which streams back tokens.
/// 3. The streaming response is parsed into sentences with emotion tags.
/// 4. Each sentence is sent to TTS in parallel, with results queued for ordered playback.
/// 5. During playback, audio amplitude drives lip sync on the character model.
/// 6. The complete response is added to conversation history.
/// 7. Server-pushed notifications (cron results) follow the same TTS+playback pipeline.
@MainActor
final class ConversationController: ObservableObject {

    // MARK: - Published State

    /// Whether the controller is currently processing a message (LLM streaming, TTS, playback).
    @Published private(set) var isProcessing: Bool = false

    /// Whether the STT service is actively listening for voice input.
    @Published private(set) var isListening: Bool = false

    /// Whether audio is currently being played back.
    @Published private(set) var isSpeaking: Bool = false

    /// Live streaming text from the LLM, shown token-by-token in the chat UI.
    @Published private(set) var streamingText: String = ""

    /// Whether the LLM token stream is active (waiting for or receiving tokens).
    ///
    /// Distinct from `isProcessing`, which stays true through TTS synthesis and
    /// playback. The chat typing indicator is gated on this flag so it disappears
    /// the moment the response text is committed, rather than lingering while 小光
    /// is still speaking.
    @Published private(set) var isStreaming: Bool = false

    /// The most recent error, if any. Cleared on next interaction.
    @Published var lastError: Error?

    /// Whether TTS voice output is enabled. When false, text and expressions still work but no audio plays.
    var ttsEnabled: Bool = true

    // MARK: - Dependencies

    private let chatTransport: any ChatTransport
    private let ttsService: TTSServiceProtocol
    private let sttService: STTServiceProtocol?
    private let audioPlayer: AudioPlayerService
    private let history: ConversationHistory
    private weak var characterController: (any CharacterControllerProtocol)?

    // MARK: - Internal State

    /// The current processing task, held for cancellation support.
    private var processingTask: Task<Void, Never>?

    /// Long-lived task that listens to chat transport events.
    private var eventListenerTask: Task<Void, Never>?

    /// Observation of the chat transport connection state.
    private var connectionStateCancellable: AnyCancellable?

    /// The ref ID of the current active chat request.
    private var currentChatRef: String?

    /// Continuation for bridging chat tokens into an AsyncThrowingStream.
    private var tokenContinuation: AsyncThrowingStream<String, Error>.Continuation?

    /// The ref ID of the current notification being processed.
    private var currentNotifyRef: String?

    /// Continuation for bridging notification tokens into an AsyncThrowingStream.
    private var notifyContinuation: AsyncThrowingStream<String, Error>.Continuation?

    /// Task for processing server-pushed notifications.
    private var notificationTask: Task<Void, Never>?

    /// Lip sync observation subscription.
    private var amplitudeCancellable: AnyCancellable?

    /// Monotonically increasing counter to identify each pipeline invocation.
    /// Used to prevent stale cleanup from clobbering a newer pipeline's state.
    private var pipelineGeneration: UInt64 = 0

    /// The localized character persona (system prompt + proactive prompt templates).
    private let persona: Persona

    /// The system prompt for the current language (from `persona`).
    private let systemPrompt: String

    /// GCD timer that fires after inactivity to trigger a proactive message.
    /// Uses DispatchSourceTimer with `.strict` to fire even during App Nap.
    private var proactiveTimer: DispatchSourceTimer?

    /// Inactivity duration (in seconds) before 小光 speaks up.
    private let proactiveInterval: TimeInterval = 3600 // 60 minutes

    /// Whether the launch greeting has already been sent this session.
    private var hasGreetedOnLaunch: Bool = false

    /// Index of the last idle task chosen, to avoid repeats.
    private var lastIdleTaskIndex: Int = -1

    // MARK: - Initialization

    /// Creates a new conversation controller with all required dependencies.
    init(
        chatTransport: any ChatTransport,
        ttsService: TTSServiceProtocol,
        sttService: STTServiceProtocol? = nil,
        audioPlayer: AudioPlayerService,
        history: ConversationHistory,
        characterController: (any CharacterControllerProtocol)? = nil
    ) {
        self.chatTransport = chatTransport
        self.ttsService = ttsService
        self.sttService = sttService
        self.audioPlayer = audioPlayer
        self.history = history
        self.characterController = characterController
        let persona = Persona.load(language: AppLanguage.current)
        self.persona = persona
        self.systemPrompt = persona.systemPrompt

        startEventListener()
        observeConnectionState()
    }

    // MARK: - Public Methods

    /// Set or update the character controller reference.
    func setCharacterController(_ controller: any CharacterControllerProtocol) {
        self.characterController = controller
    }

    /// Send a user message and process the full conversation pipeline.
    ///
    /// This method orchestrates the entire flow: chat streaming -> sentence parsing ->
    /// parallel TTS synthesis -> ordered audio playback with lip sync.
    ///
    /// Can be called while another pipeline is active — the previous pipeline is cancelled
    /// and a new one starts immediately.
    ///
    /// - Parameter text: The user's message text.
    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any ongoing processing (including notifications).
        cancelInternal()

        pipelineGeneration &+= 1
        let generation = pipelineGeneration

        lastError = nil
        isProcessing = true

        history.addUserMessage(trimmed)

        // Run the pipeline in a cancellable task.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.runPipeline()
            } catch is CancellationError {
                // Cancellation is expected; no error to report.
            } catch {
                self.lastError = error
            }

            self.cleanupPipeline(generation: generation)
        }

        processingTask = task

        // Await the task so `sendMessage` only returns when the pipeline is done.
        await task.value
    }

    // MARK: - Pipeline Cleanup

    /// Conditionally reset pipeline state. Only runs if no newer pipeline has started,
    /// preventing a cancelled pipeline's cleanup from clobbering an active one.
    private func cleanupPipeline(generation: UInt64) {
        guard generation == pipelineGeneration else { return }
        isProcessing = false
        isStreaming = false
        isSpeaking = false
        stopLipSyncObservation()
        characterController?.setMouthOpen(0)
        resetProactiveTimer()
    }

    /// Start voice input via the STT service.
    func startVoiceInput() async {
        Log.pipeline("[Pipeline] startVoiceInput called, sttService=\(sttService != nil), isListening=\(isListening)")
        guard let sttService, !isListening else {
            Log.pipeline("[Pipeline] startVoiceInput guard failed — sttService nil or already listening")
            return
        }

        // Barge-in: if 小光 is currently speaking (or mid-pipeline), stop her voice and
        // tear down the active pipeline before opening the mic. This prevents the TTS
        // audio from bleeding into the microphone capture.
        if isProcessing || isSpeaking {
            Log.pipeline("[Pipeline] Barge-in — stopping active playback before listening")
            cancelInternal()
        }

        isListening = true
        lastError = nil

        do {
            Log.pipeline("[Pipeline] Calling sttService.startListening...")
            let stream = sttService.startListening(locale: Locale(identifier: AppLanguage.current.sttLocaleIdentifier))
            var finalTranscription: String = ""

            for try await transcription in stream {
                finalTranscription = transcription
            }

            isListening = false

            let trimmed = finalTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await sendMessage(trimmed)
            }
        } catch {
            isListening = false
            lastError = error
        }
    }

    /// Stop voice input.
    func stopVoiceInput() {
        sttService?.stopListening()
        isListening = false
    }

    /// Cancel any ongoing processing, stop audio playback, and reset state.
    func cancel() {
        cancelInternal()
        lastError = nil
    }

    // MARK: - Proactive Chat

    /// Trigger a one-time greeting when the app launches.
    func triggerLaunchGreeting() {
        guard !hasGreetedOnLaunch else { return }
        hasGreetedOnLaunch = true

        Task { @MainActor [weak self] in
            // Wait for model to load before greeting.
            try? await Task.sleep(for: .seconds(5))
            guard let self, !self.isProcessing else { return }

            let timeString = Self.formattedCurrentTime()
            let prompt = self.persona.launchGreetingTemplate
                .replacingOccurrences(of: "{time}", with: timeString)
            await self.sendProactiveMessage(prompt: prompt)
        }
    }

    /// Send a proactive message by injecting a hidden system instruction.
    func sendProactiveMessage(prompt: String? = nil) async {
        guard !isProcessing else {
            Log.pipeline("[Pipeline] sendProactiveMessage ignored — already processing")
            return
        }

        cancelInternal()

        pipelineGeneration &+= 1
        let generation = pipelineGeneration

        lastError = nil
        isProcessing = true

        let timeString = Self.formattedCurrentTime()
        let instruction = prompt ?? buildIdleTaskPrompt(time: timeString)

        history.addUserMessage(instruction, isHidden: true)
        let messageCountBeforePipeline = history.messages.count

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.runPipeline()
            } catch is CancellationError {
                // Cancellation is expected.
            } catch {
                self.lastError = error
            }

            // If LLM returned empty, remove the proactive instruction to avoid polluting history.
            if self.history.messages.count == messageCountBeforePipeline,
               let last = self.history.messages.last, last.role == .user {
                self.history.removeLastMessage()
            }

            self.cleanupPipeline(generation: generation)
        }

        processingTask = task
        await task.value
    }

    /// Schedule the proactive timer to fire after the inactivity interval.
    /// Uses DispatchSourceTimer with `.strict` flag to bypass macOS App Nap.
    private func startProactiveTimer() {
        proactiveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + proactiveInterval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.sendProactiveMessage()
            }
        }
        proactiveTimer = timer
        timer.resume()
    }

    /// Reset the proactive timer (called after any message completes).
    private func resetProactiveTimer() {
        startProactiveTimer()
    }

    /// Format the current date/time in a human-readable string for the active language.
    private static func formattedCurrentTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    /// Build an idle task prompt from the localized persona, rotating through the
    /// tasks to avoid repeats. Tasks are tool-agnostic natural-language intents — if
    /// the backend has tools configured the agent uses them, otherwise it answers
    /// from the model.
    private func buildIdleTaskPrompt(time: String) -> String {
        let tasks = persona.idleTasks
        let task: String
        if tasks.isEmpty {
            task = ""
        } else {
            var index = Int.random(in: 0..<tasks.count)
            if index == lastIdleTaskIndex {
                index = (index + 1) % tasks.count
            }
            lastIdleTaskIndex = index
            task = tasks[index]
        }

        return persona.idlePromptTemplate
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{task}", with: task)
    }

    // MARK: - Event Listener

    /// Start a long-lived task that consumes the chat transport event stream.
    private func startEventListener() {
        eventListenerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.chatTransport.events {
                guard !Task.isCancelled else { return }
                self.handleEvent(event)
            }
        }
    }

    /// Dispatch an incoming chat transport event to the appropriate handler.
    private func handleEvent(_ event: WSIncoming) {
        switch event {
        case .token(let ref, let content, _):
            if ref == currentChatRef {
                tokenContinuation?.yield(content)
            } else if ref == currentNotifyRef {
                notifyContinuation?.yield(content)
            }

        case .done(let ref, _):
            if ref == currentChatRef {
                tokenContinuation?.finish()
                tokenContinuation = nil
                currentChatRef = nil
            } else if ref == currentNotifyRef {
                notifyContinuation?.finish()
                notifyContinuation = nil
            }

        case .error(let ref, let message):
            let error = ChatTransportError.serverError(message)
            if ref == currentChatRef {
                tokenContinuation?.finish(throwing: error)
                tokenContinuation = nil
                currentChatRef = nil
            } else if ref == currentNotifyRef {
                notifyContinuation?.finish(throwing: error)
                notifyContinuation = nil
            } else {
                Log.pipeline("[Pipeline] Server error: \(message)")
                lastError = error
            }

        case .notify(let ref, let source):
            handleNotification(ref: ref, source: source)

        case .welcome, .heartbeat:
            break
        }
    }

    // MARK: - Connection State Observation

    /// Watch for disconnection while a stream is active.
    private func observeConnectionState() {
        connectionStateCancellable = chatTransport.connectionStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .disconnected {
                    // If we have an active token stream, fail it so the pipeline resets.
                    if self.tokenContinuation != nil {
                        self.tokenContinuation?.finish(throwing: ChatTransportError.notConnected)
                        self.tokenContinuation = nil
                        self.currentChatRef = nil
                    }
                    if self.notifyContinuation != nil {
                        self.notifyContinuation?.finish(throwing: ChatTransportError.notConnected)
                        self.notifyContinuation = nil
                        self.currentNotifyRef = nil
                    }
                }
            }
    }

    // MARK: - Notification Pipeline

    /// Handle a server-pushed notification (e.g. cron job result).
    private func handleNotification(ref: String, source: String) {
        // If user is chatting, ignore the notification (user takes priority).
        guard !isProcessing else {
            Log.pipeline("[Pipeline] Notification \(ref) ignored — user is processing")
            // Ack anyway so the backend does not retry.
            Task { try? await chatTransport.send(.ack(ref: ref)) }
            return
        }

        Log.pipeline("[Pipeline] Starting notification pipeline: ref=\(ref), source=\(source)")

        pipelineGeneration &+= 1
        let generation = pipelineGeneration

        isProcessing = true
        currentNotifyRef = ref

        let (tokenStream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.notifyContinuation = continuation

        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.runNotificationPipeline(tokenStream: tokenStream)
            } catch is CancellationError {
                // Cancelled (e.g. user sent a message).
            } catch {
                Log.pipeline("[Pipeline] Notification error (non-fatal): \(error.localizedDescription)")
            }

            self.cleanupPipeline(generation: generation)
            self.currentNotifyRef = nil

            // Ack the notification.
            try? await self.chatTransport.send(.ack(ref: ref))
        }
    }

    /// Process a notification's token stream through the TTS+playback pipeline.
    private func runNotificationPipeline(tokenStream: AsyncThrowingStream<String, Error>) async throws {
        let parser = SentenceParser()
        let audioQueue = AudioQueue()
        let pipelineState = PipelineState()
        let charController = characterController

        isStreaming = true
        startLipSyncObservation()
        charController?.playAnimation(named: "think")

        // Consume the token stream (tokens arrive via handleEvent).
        do {
            var rawResponse = ""
            for try await chunk in tokenStream {
                try Task.checkCancellation()
                rawResponse.append(chunk)
                streamingText.append(chunk)
                await parser.feed(chunk)
                await Task.yield()
            }
            await parser.finish()
            await pipelineState.setRawResponse(rawResponse)
        } catch is CancellationError {
            await parser.finish()
            throw CancellationError()
        } catch {
            await parser.finish()
            throw error
        }

        charController?.stopAnimation()

        let rawResponse = await pipelineState.getRawResponse()
        Log.pipeline("[Pipeline] Notification response received (\(rawResponse.count) chars)")
        if !rawResponse.isEmpty {
            history.addAssistantMessage(rawResponse)
        }
        streamingText = ""
        isStreaming = false

        // TTS + playback (same as chat pipeline, skip when TTS is disabled).
        if ttsEnabled {
            try await runTTSPlayback(parser: parser, audioQueue: audioQueue, charController: charController)
        }
    }

    // MARK: - Pipeline

    /// The core pipeline: send chat via the transport -> parse sentences -> TTS in parallel -> play in order.
    private func runPipeline() async throws {
        let contextMessages = buildMessagesWithSystemPrompt()
        let apiMessages = contextMessages.map { $0.apiMessage }

        let parser = SentenceParser()
        let audioQueue = AudioQueue()
        let pipelineState = PipelineState()
        let charController = characterController

        // Create bridge stream for tokens.
        let (tokenStream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.tokenContinuation = continuation
        let chatId = UUID().uuidString
        self.currentChatRef = chatId

        // Send chat request via the transport.
        try await chatTransport.send(.chat(id: chatId, messages: apiMessages))

        isStreaming = true
        startLipSyncObservation()
        charController?.playAnimation(named: "think")

        // Consume the token stream (tokens arrive via handleEvent → yield to continuation).
        do {
            var rawResponse = ""
            for try await chunk in tokenStream {
                try Task.checkCancellation()
                rawResponse.append(chunk)
                streamingText.append(chunk)
                await parser.feed(chunk)
                await Task.yield()
            }
            await parser.finish()
            await pipelineState.setRawResponse(rawResponse)
        } catch is CancellationError {
            await parser.finish()
            throw CancellationError()
        } catch {
            await parser.finish()
            throw error
        }

        charController?.stopAnimation()

        let rawResponse = await pipelineState.getRawResponse()
        if !rawResponse.isEmpty {
            history.addAssistantMessage(rawResponse)
        }
        streamingText = ""
        isStreaming = false

        // TTS + playback (non-fatal, skip when TTS is disabled).
        if ttsEnabled {
            try await runTTSPlayback(parser: parser, audioQueue: audioQueue, charController: charController)
        }
    }

    // MARK: - TTS + Playback (shared)

    /// Run TTS synthesis and ordered audio playback for parsed sentences.
    /// Shared between chat pipeline and notification pipeline.
    private func runTTSPlayback(
        parser: SentenceParser,
        audioQueue: AudioQueue,
        charController: (any CharacterControllerProtocol)?
    ) async throws {
        do {
            var sentences: [SentenceChunk] = []
            for await sentence in parser.sentences {
                Log.pipeline("[Pipeline] Parsed sentence: emotion=\(sentence.emotion.rawValue), text=\"\(sentence.text)\"")
                sentences.append(sentence)
            }

            Log.pipeline("[Pipeline] Total parsed sentences: \(sentences.count)")
            guard !sentences.isEmpty else {
                Log.pipeline("[Pipeline] No sentences parsed — skipping TTS")
                return
            }

            if let lastEmotion = sentences.last?.emotion {
                charController?.setExpression(lastEmotion, blendDuration: 0.3)
            }

            charController?.playAnimation(named: "talk_gesture")

            Log.pipeline("[Pipeline] Starting TTS for \(sentences.count) sentences")
            let capturedSentences = sentences
            try await withThrowingTaskGroup(of: Void.self) { group in
                let ttsService = self.ttsService

                // TTS producer.
                group.addTask { @Sendable [ttsService, charController, capturedSentences] in
                    for (index, sentence) in capturedSentences.enumerated() {
                        try Task.checkCancellation()

                        let emotion = sentence.emotion
                        await MainActor.run {
                            charController?.setExpression(emotion, blendDuration: 0.3)
                        }

                        Log.pipeline("[Pipeline] TTS[\(index)] synthesizing: \"\(sentence.text)\"")
                        var audioData = Data()
                        let ttsStream = ttsService.synthesize(
                            text: sentence.text,
                            emotion: sentence.emotion
                        )
                        for try await chunk in ttsStream {
                            try Task.checkCancellation()
                            audioData.append(chunk)
                        }

                        Log.pipeline("[Pipeline] TTS[\(index)] received \(audioData.count) bytes")
                        if !audioData.isEmpty {
                            await audioQueue.enqueue(sequence: index, audioData: audioData)
                        }
                    }
                    await audioQueue.markFinished()
                    Log.pipeline("[Pipeline] TTS producer finished")
                }

                // Audio consumer.
                let audioPlayerRef = audioPlayer
                group.addTask { @Sendable [charController] in
                    Log.pipeline("[Pipeline] Audio consumer started")
                    await MainActor.run {
                        self.isSpeaking = true
                    }
                    while let segment = await audioQueue.dequeueNext() {
                        try Task.checkCancellation()
                        Log.pipeline("[Pipeline] Playing segment #\(segment.sequence) (\(segment.data.count) bytes)")
                        try await audioPlayerRef.playAudioData(segment.data)
                    }
                    Log.pipeline("[Pipeline] Audio consumer finished")
                    await MainActor.run {
                        self.isSpeaking = false
                        charController?.setMouthOpen(0)
                    }
                }

                try await group.waitForAll()
            }
            charController?.stopAnimation()
            Log.pipeline("[Pipeline] TTS+playback complete")
        } catch {
            charController?.stopAnimation()
            Log.pipeline("[Pipeline] TTS/playback error (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Lip Sync

    private func startLipSyncObservation() {
        guard amplitudeCancellable == nil else { return }

        amplitudeCancellable = audioPlayer.$currentAmplitude
            .receive(on: RunLoop.main)
            .sink { [weak self] amplitude in
                self?.characterController?.setMouthOpen(amplitude)
            }
    }

    private func stopLipSyncObservation() {
        amplitudeCancellable?.cancel()
        amplitudeCancellable = nil
    }

    // MARK: - Cancellation

    private func cancelInternal() {
        // Cancel active chat stream.
        if let ref = currentChatRef {
            tokenContinuation?.finish(throwing: CancellationError())
            tokenContinuation = nil
            currentChatRef = nil
            Task { try? await chatTransport.send(.cancel(ref: ref)) }
        }

        // Cancel active notification stream.
        if let ref = currentNotifyRef {
            notifyContinuation?.finish(throwing: CancellationError())
            notifyContinuation = nil
            currentNotifyRef = nil
            Task { try? await chatTransport.send(.ack(ref: ref)) }
        }
        notificationTask?.cancel()
        notificationTask = nil

        processingTask?.cancel()
        processingTask = nil

        proactiveTimer?.cancel()
        proactiveTimer = nil

        audioPlayer.stop()
        stopLipSyncObservation()

        if isListening {
            sttService?.stopListening()
            isListening = false
        }

        isProcessing = false
        isStreaming = false
        isSpeaking = false
        streamingText = ""

        characterController?.setMouthOpen(0)
        characterController?.stopAnimation()
        characterController?.playIdleAnimation()
    }

    // MARK: - System Prompt

    /// Build the full messages array with the system prompt as the first message.
    private func buildMessagesWithSystemPrompt() -> [ChatMessage] {
        var messages: [ChatMessage] = []

        messages.append(ChatMessage(role: .system, content: systemPrompt))
        messages.append(contentsOf: history.contextMessages)

        // Ensure at least one user message exists for backend compatibility.
        let hasUserMessage = messages.contains { $0.role == .user }
        if !hasUserMessage, let lastSystemIndex = messages.lastIndex(where: { $0.role == .system }),
           lastSystemIndex > 0 {
            let original = messages[lastSystemIndex]
            messages[lastSystemIndex] = ChatMessage(role: .user, content: original.content)
        }

        return messages
    }

    // MARK: - Text Utilities

    /// Strip emotion tags from a string for clean display/history storage.
    static func stripEmotionTags(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\[(neutral|happy|sad|angry|surprised|curious|excited|shy|love|smirk|sleepy|proud|disgusted|pain|laugh|bored)\]\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Pipeline State

/// Actor that holds mutable shared state for the conversation pipeline.
private actor PipelineState {

    private var rawResponse: String = ""

    func setRawResponse(_ text: String) {
        rawResponse = text
    }

    func getRawResponse() -> String {
        rawResponse
    }
}

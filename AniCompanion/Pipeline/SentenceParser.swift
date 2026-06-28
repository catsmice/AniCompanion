import Foundation

// MARK: - Types

/// A parsed sentence chunk with its associated emotion.
struct SentenceChunk: Sendable {
    let text: String
    let emotion: Emotion
}

// MARK: - SentenceParser

/// Streaming sentence parser that buffers LLM output and emits complete sentences with emotion tags.
///
/// Feed text chunks from the LLM via `feed(_:)`. The parser maintains an internal buffer and
/// detects sentence boundaries (Chinese punctuation) and emotion tags (e.g., `[happy]`). Complete
/// sentences are emitted through the `sentences` async stream.
///
/// Use `finish()` to flush any remaining buffered text as a final sentence.
actor SentenceParser {

    // MARK: - Configuration

    /// Maximum buffer length before forcing a clause-level split.
    /// Prevents excessively long TTS segments when no sentence boundary appears.
    private let maxBufferLengthBeforeClauseSplit = 50

    /// Regex pattern for emotion tags in LLM output.
    private static let emotionTagPattern = #"\[(neutral|happy|sad|angry|surprised|curious|excited|shy|love|smirk|sleepy|proud|disgusted|pain|laugh|bored)\]"#

    /// Characters that constitute sentence-ending boundaries.
    private static let sentenceBoundaries: Set<Character> = ["。", "！", "？", "\n", "～", "⋯"]

    /// Characters that constitute clause-level boundaries (used for long-buffer splits).
    private static let clauseBoundaries: Set<Character> = ["，", "、"]

    // MARK: - Internal State

    private var buffer: String = ""
    private var currentEmotion: Emotion = .neutral
    private var continuation: AsyncStream<SentenceChunk>.Continuation?
    private var isFinished: Bool = false

    // MARK: - Public Interface

    /// Async stream of parsed sentence chunks. Sentences are emitted as they are detected
    /// from the buffered input.
    nonisolated let sentences: AsyncStream<SentenceChunk>

    init() {
        var captured: AsyncStream<SentenceChunk>.Continuation?
        self.sentences = AsyncStream { continuation in
            captured = continuation
        }
        // The continuation is captured synchronously by AsyncStream's init closure,
        // so it is available immediately. We store it outside the actor's isolation
        // and assign it in a Task to satisfy actor isolation.
        let cont = captured!
        self._continuation = cont
    }

    /// Workaround: store the continuation in a non-isolated stored property set in init,
    /// then copy to the actor-isolated `continuation` on first use.
    private let _continuation: AsyncStream<SentenceChunk>.Continuation

    /// Ensures the actor-isolated continuation reference is initialized.
    private func ensureContinuation() {
        if continuation == nil {
            continuation = _continuation
        }
    }

    /// Feed a text chunk from the LLM streaming output.
    ///
    /// The parser appends the text to its internal buffer, strips any emotion tags
    /// (updating the current emotion), and emits complete sentences as they are detected.
    func feed(_ text: String) {
        guard !isFinished else { return }
        ensureContinuation()

        buffer.append(text)
        processBuffer()
    }

    /// Flush the remaining buffer as a final sentence and close the stream.
    ///
    /// Call this when the LLM stream has ended. Any remaining buffered text is emitted
    /// as a final sentence chunk.
    func finish() {
        guard !isFinished else { return }
        ensureContinuation()
        isFinished = true

        // Strip any trailing emotion tags from the buffer.
        stripLeadingEmotionTags()

        // Emit whatever remains in the buffer.
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            emitChunk(text: remaining)
        }

        buffer = ""
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Buffer Processing

    /// Process the internal buffer, extracting emotion tags and emitting sentences
    /// at detected boundaries.
    private func processBuffer() {
        // Repeatedly scan for emotion tags and sentence boundaries until no more
        // complete sentences can be extracted.
        while true {
            // First, strip any emotion tags at the beginning of the buffer.
            stripLeadingEmotionTags()

            if buffer.isEmpty { break }

            // Look for the earliest sentence boundary.
            if let sentenceEnd = findSentenceBoundary() {
                let sentenceText = String(buffer[buffer.startIndex...sentenceEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Advance the buffer past the emitted text.
                buffer = String(buffer[buffer.index(after: sentenceEnd)...])

                // Only emit non-empty sentences.
                if !sentenceText.isEmpty {
                    emitChunk(text: sentenceText)
                }
                continue
            }

            // No sentence boundary found. Check if the buffer is too long and
            // should be split at a clause boundary.
            if buffer.count > maxBufferLengthBeforeClauseSplit {
                if let clauseEnd = findClauseBoundary() {
                    let clauseText = String(buffer[buffer.startIndex...clauseEnd])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    buffer = String(buffer[buffer.index(after: clauseEnd)...])

                    if !clauseText.isEmpty {
                        emitChunk(text: clauseText)
                    }
                    continue
                }
            }

            // Neither a sentence boundary nor a clause split is applicable.
            // Wait for more input.
            break
        }
    }

    /// Strips emotion tags from the beginning of the buffer, updating `currentEmotion`
    /// for each tag found. Handles consecutive tags like `[happy][excited]`.
    private func stripLeadingEmotionTags() {
        guard let regex = try? NSRegularExpression(
            pattern: "^\\s*" + Self.emotionTagPattern,
            options: []
        ) else { return }

        while true {
            let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
            guard let match = regex.firstMatch(in: buffer, options: [], range: range) else {
                break
            }

            // Extract the emotion name from the capture group.
            if let captureRange = Range(match.range(at: 1), in: buffer) {
                let emotionName = String(buffer[captureRange])
                if let emotion = Emotion.from(tag: emotionName) {
                    currentEmotion = emotion
                }
            }

            // Remove the matched tag from the buffer.
            if let matchRange = Range(match.range(at: 0), in: buffer) {
                buffer.removeSubrange(buffer.startIndex..<matchRange.upperBound)
            } else {
                break
            }
        }

        // Also handle emotion tags that appear mid-buffer (not at the start).
        // Replace them inline and update emotion state.
        stripInlineEmotionTags()
    }

    /// Scan the buffer for emotion tags anywhere in the text, updating the current
    /// emotion and removing the tag from the buffer.
    ///
    /// Tags are collected in forward order (so the last tag in the buffer wins for
    /// `currentEmotion`), then removed in reverse order so indices remain valid.
    private func stripInlineEmotionTags() {
        guard let regex = try? NSRegularExpression(
            pattern: Self.emotionTagPattern,
            options: []
        ) else { return }

        let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
        let matches = regex.matches(in: buffer, options: [], range: range)

        guard !matches.isEmpty else { return }

        // Update emotion in forward order so the latest tag in the text takes effect.
        for match in matches {
            if let captureRange = Range(match.range(at: 1), in: buffer) {
                let emotionName = String(buffer[captureRange])
                if let emotion = Emotion.from(tag: emotionName) {
                    currentEmotion = emotion
                }
            }
        }

        // Remove tags in reverse order so removal indices remain valid.
        for match in matches.reversed() {
            if let matchRange = Range(match.range(at: 0), in: buffer) {
                buffer.removeSubrange(matchRange)
            }
        }
    }

    /// Find the index of the earliest sentence-ending boundary character in the buffer.
    private func findSentenceBoundary() -> String.Index? {
        for (index, char) in buffer.enumerated() {
            if Self.sentenceBoundaries.contains(char) {
                return buffer.index(buffer.startIndex, offsetBy: index)
            }
        }
        return nil
    }

    /// Find the index of the last clause boundary character in the buffer.
    /// Uses the *last* clause boundary to maximize chunk size while staying under the limit.
    private func findClauseBoundary() -> String.Index? {
        var lastClauseIndex: String.Index?
        for (index, char) in buffer.enumerated() {
            if Self.clauseBoundaries.contains(char) {
                lastClauseIndex = buffer.index(buffer.startIndex, offsetBy: index)
            }
        }
        return lastClauseIndex
    }

    /// Emit a sentence chunk through the async stream.
    private func emitChunk(text: String) {
        continuation?.yield(SentenceChunk(text: text, emotion: currentEmotion))
    }
}

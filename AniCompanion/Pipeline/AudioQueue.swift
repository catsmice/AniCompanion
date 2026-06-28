import Foundation

// MARK: - AudioQueue

/// A FIFO queue for ordered TTS audio playback.
///
/// Audio segments are enqueued with sequence numbers and may arrive out of order when
/// TTS requests are parallelized. `dequeueNext()` waits until the next expected sequence
/// number is available, ensuring playback order matches the original text order.
actor AudioQueue {

    // MARK: - Types

    /// An audio segment with its assigned sequence number.
    private struct AudioSegment {
        let sequence: Int
        let data: Data
    }

    // MARK: - State

    /// The next sequence number expected for playback.
    private var nextExpectedSequence: Int = 0

    /// Buffer for segments that arrived ahead of order.
    private var pendingSegments: [Int: Data] = [:]

    /// Continuation for the consumer waiting on the next segment.
    /// Only one consumer (the playback loop) should be waiting at a time.
    private var waiter: CheckedContinuation<(sequence: Int, data: Data)?, Never>?

    /// Whether the queue has been marked as finished (no more segments will be enqueued).
    private var isFinished: Bool = false

    // MARK: - Public Interface

    /// Whether the queue currently has no buffered (pending) segments.
    var isEmpty: Bool {
        pendingSegments.isEmpty
    }

    /// Enqueue an audio segment with its sequence number.
    ///
    /// Segments may arrive in any order. If the enqueued segment is the one the consumer
    /// is currently waiting for, it is delivered immediately.
    ///
    /// - Parameters:
    ///   - sequence: The sequence number for this segment (0-based, assigned in text order).
    ///   - audioData: The raw audio data (e.g., MP3 bytes) for this segment.
    func enqueue(sequence: Int, audioData: Data) {
        guard !isFinished else { return }

        // If a consumer is waiting and this is the next expected sequence, deliver directly.
        if sequence == nextExpectedSequence, let waiter = self.waiter {
            self.waiter = nil
            nextExpectedSequence += 1
            waiter.resume(returning: (sequence: sequence, data: audioData))

            return
        }

        // Otherwise, buffer the segment for later retrieval.
        pendingSegments[sequence] = audioData
    }

    /// Wait for and return the next expected audio segment.
    ///
    /// If the next expected segment is already buffered, it is returned immediately.
    /// Otherwise, this method suspends until the segment arrives via `enqueue(sequence:audioData:)`
    /// or the queue is finished.
    ///
    /// - Returns: The next audio segment in sequence order, or `nil` if the queue is finished
    ///   and no more segments are expected.
    func dequeueNext() async -> (sequence: Int, data: Data)? {
        // Check if the next expected segment is already buffered.
        if let data = pendingSegments.removeValue(forKey: nextExpectedSequence) {
            let seq = nextExpectedSequence
            nextExpectedSequence += 1
            return (sequence: seq, data: data)
        }

        // If the queue is finished and we don't have the next segment, we're done.
        if isFinished {
            return nil
        }

        // Suspend until the segment arrives or the queue is finished.
        return await withCheckedContinuation { continuation in
            self.waiter = continuation
        }
    }

    /// Mark the queue as finished, indicating no more segments will be enqueued.
    ///
    /// If a consumer is currently waiting, it is woken up with `nil` (provided the
    /// expected segment is not already buffered).
    func markFinished() {
        isFinished = true

        // If a waiter is waiting and the expected segment is buffered, deliver it.
        if let waiter = self.waiter {
            if let data = pendingSegments.removeValue(forKey: nextExpectedSequence) {
                self.waiter = nil
                let seq = nextExpectedSequence
                nextExpectedSequence += 1
                waiter.resume(returning: (sequence: seq, data: data))
            } else {
                // No more segments coming and the expected one isn't buffered.
                self.waiter = nil
                waiter.resume(returning: nil)
            }
        }
    }

    /// Reset the queue to its initial state, discarding all pending segments.
    ///
    /// If a consumer is waiting, it receives `nil` to indicate cancellation.
    func reset() {
        pendingSegments.removeAll()
        nextExpectedSequence = 0
        isFinished = false

        // Wake up any waiting consumer with nil.
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

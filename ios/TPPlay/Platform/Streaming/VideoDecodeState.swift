// Pure state machine. VideoDecoder owns the lock around every access.
// Counts include the frame currently being decoded, not just dispatch blocks.
struct VideoDecodeState {
    static let maximumFrames = 12
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumAgeNanoseconds: UInt64 = 200_000_000

    private(set) var pendingFrames = 0
    private(set) var pendingBytes = 0
    private(set) var stopped = false
    private(set) var recovering = false
    private(set) var recoveryGeneration: UInt64 = 0
    private var resetPending = false

    mutating func reserve(bytes: Int) -> Bool {
        guard !stopped, bytes > 0, pendingFrames < Self.maximumFrames,
              bytes <= Self.maximumBytes - pendingBytes else { return false }
        pendingFrames += 1
        pendingBytes += bytes
        return true
    }

    mutating func complete(bytes: Int) {
        precondition(pendingFrames > 0 && bytes >= 0 && bytes <= pendingBytes)
        pendingFrames -= 1
        pendingBytes -= bytes
    }

    // Return true only for the first request in a recovery episode. Increment
    // the generation on every error so an older keyframe cannot clear a newer error.
    @discardableResult
    mutating func requestRecovery() -> Bool {
        guard !stopped else { return false }
        let firstRequest = !recovering
        recovering = true
        resetPending = true
        recoveryGeneration &+= 1
        return firstRequest
    }

    mutating func consumeReset() -> Bool {
        let result = resetPending
        resetPending = false
        return result
    }

    mutating func finishRecovery(generation: UInt64) {
        guard !stopped, generation == recoveryGeneration else { return }
        recovering = false
    }

    mutating func stop() { stopped = true }

    static func isExpired(receivedAt: UInt64, now: UInt64) -> Bool {
        now >= receivedAt && now - receivedAt > maximumAgeNanoseconds
    }
}

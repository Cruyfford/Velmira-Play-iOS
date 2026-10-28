func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

var flow = VideoDecodeState()
for _ in 0..<VideoDecodeState.maximumFrames {
    require(flow.reserve(bytes: 100), "Normal burst must fit")
}
require(!flow.reserve(bytes: 100), "Bound outstanding decode work")
require(flow.pendingFrames == VideoDecodeState.maximumFrames, "Rejected frames do not count")
flow.complete(bytes: 100)
require(flow.reserve(bytes: 100), "Completion must free capacity")
for _ in 0..<VideoDecodeState.maximumFrames { flow.complete(bytes: 100) }
require(flow.pendingFrames == 0 && flow.pendingBytes == 0, "Drain all work")
require(!flow.reserve(bytes: 0), "Empty input must not occupy a slot")
require(!flow.reserve(bytes: -1), "Invalid size must fail")
require(!flow.reserve(bytes: Int.max), "Oversized input must not overflow counters")
require(flow.reserve(bytes: VideoDecodeState.maximumBytes), "Exact byte limit must fit")
require(!flow.reserve(bytes: 1), "Bound compressed memory too")
flow.complete(bytes: VideoDecodeState.maximumBytes)

require(flow.requestRecovery(), "First error must request a keyframe")
let previousGeneration = flow.recoveryGeneration
require(flow.consumeReset(), "First request resets decoder")
require(!flow.consumeReset(), "Do not repeatedly reset while awaiting keyframe")
require(!flow.requestRecovery(), "Coalesce repeated recovery notifications")
flow.finishRecovery(generation: previousGeneration)
require(flow.recovering, "Old keyframe must not clear a newer error")
require(flow.consumeReset(), "A newer error needs a fresh reset")
flow.finishRecovery(generation: flow.recoveryGeneration)
require(!flow.recovering, "Current successful keyframe completes recovery")
require(flow.requestRecovery(), "Later independent error must notify again")

let start: UInt64 = 1_000_000_000
require(!VideoDecodeState.isExpired(receivedAt: start, now: start + 200_000_000), "Boundary is allowed")
require(VideoDecodeState.isExpired(receivedAt: start, now: start + 200_000_001), "Discard stale input")
require(!VideoDecodeState.isExpired(receivedAt: start, now: start - 1), "Clock comparison must not underflow")
require(flow.reserve(bytes: 100), "Admit final frame")
flow.stop()
require(!flow.reserve(bytes: 100), "Reject late callbacks after stop")
require(!flow.requestRecovery(), "Never request IDR after stop")
flow.complete(bytes: 100)
require(flow.pendingFrames == 0, "Already admitted work can drain after stop")
print("Streaming state checks passed")

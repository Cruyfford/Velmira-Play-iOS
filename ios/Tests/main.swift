import Foundation

func require(_ condition: @autoclosure () -> Bool, _ description: String) {
    if !condition() { fatalError(description) }
}
let box = CGRect(x: 0.51, y: 0.30, width: 0.10, height: 0.40)
var c = AssistanceConfiguration()
c.pointY = 0.5
var engine = TrackingEngine()
func run(_ t: Double, armed: Bool = true, l2: Double = 1, r2: Double = 0,
         rawX: Double = 0, sample: TrackingSample? = nil) -> AssistanceOutput {
    engine.step(now: t, armed: armed, l2: l2, r2: r2, rawX: rawX, rawY: 0, sample: sample, config: c)
}
let fresh = TrackingSample(boxes: [box], capturedAt: 1, colorMode: false)
require(run(0.9, sample: fresh).x == 0, "Must release triggers before enabling assistance")
_ = run(0.95, l2: 0)
let tracked = run(1, sample: fresh)
require(tracked.x > 0 && tracked.x <= c.maxStick, "Right-side target must move right within cap")
require(tracked.target != nil, "Must select candidate")
require(run(1.1, rawX: 0.8, sample: fresh).x == 0.8, "Manual movement has priority")
require(run(2, sample: fresh).x == 0, "Old video must not move the aim")
require(run(2.1, l2: 0, sample: fresh).x == 0, "L2 release stops assistance")
// Lock the original box; do not jump to a separate, closer box.
let other = CGRect(x: 0.43, y: 0.45, width: 0.04, height: 0.10)
_ = run(3, sample: TrackingSample(boxes: [box], capturedAt: 3, colorMode: false))
let locked = run(3.1, sample: TrackingSample(boxes: [box, other], capturedAt: 3.1, colorMode: false))
require(locked.target!.x > 0.5, "Do not switch to a new closer target while locked")
require(run(3.2, sample: TrackingSample(boxes: [other], capturedAt: 3.2, colorMode: false)).target == nil, "Do not jump on one missed frame")
require(run(4, sample: TrackingSample(boxes: [other], capturedAt: 4, colorMode: false)).target == nil, "Switch disabled requires release")
_ = run(4.1, l2: 0)
c.switchOnLoss = true
_ = run(5, sample: TrackingSample(boxes: [box], capturedAt: 5, colorMode: false))
let switched = run(6, sample: TrackingSample(boxes: [other], capturedAt: 6, colorMode: false))
require(switched.target!.x < 0.5, "Switch enabled reacquires after timeout")
_ = run(6.1, l2: 0)
c.quickScope = true; c.silentShot = true
_ = run(7)
require(!run(7.1).fire, "Quick scope waits for configured delay")
require(run(7.31).fire, "Quick scope presses R2 in pulse window")
require(!run(7.40).fire, "R2 pulse ends")
require(run(7.44).switchWeapon, "Triangle follows the shot")
require(!run(7.6).switchWeapon && !run(8).fire, "No repeating macro while L2 remains held")
_ = run(8.1, l2: 0)
_ = run(9)
require(!run(9.31, armed: false).fire, "Disarming cancels pending macro")
engine.reset()
_ = run(10, l2: 0)
c.quickScope = false; c.silentShot = false; c.recoil = true
require(run(11, r2: 1).y == c.recoilY, "Recoil compensation during L2+R2")
require(run(11.1, l2: 0, r2: 1).y == 0, "Recoil stops without L2")
print("TrackingEngine behavioral assertions passed")

// Verify color extraction on real CoreVideo buffers, including vertical coordinates.
import CoreVideo
var pixelBuffer: CVPixelBuffer?
require(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess, "Create BGRA fixture")
let buffer = pixelBuffer!
CVPixelBufferLockBaseAddress(buffer, [])
let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
let pitch = CVPixelBufferGetBytesPerRow(buffer)
pixels.initialize(repeating: 0, count: pitch * 128)
for y in 16..<32 {
    for x in 64..<88 {
        pixels[y * pitch + x * 4 + 2] = 255
        pixels[y * pitch + x * 4 + 3] = 255
    }
}
CVPixelBufferUnlockBaseAddress(buffer, [])
let colorBoxes = try ColorTargetDetector.detect(buffer, configuration: ColorTrackingConfiguration())
require(colorBoxes.count == 1, "Red nameplate is one component")
require(abs(colorBoxes[0].minX - 0.5) < 0.001, "Color X normalization")
require(abs(colorBoxes[0].maxY - 0.875) < 0.001, "Top image rows map to high Vision Y")
var blue = ColorTrackingConfiguration(); blue.hue = 0.66
let rejected = try ColorTargetDetector.detect(buffer, configuration: blue)
require(rejected.isEmpty, "Blue selection rejects red pixels")
print("Color detector checks passed")


// Conservative image detection verification: no one-frame false positives.
var persistence = StableDetectionFilter()
let markA = CGRect(x: 0.20, y: 0.40, width: 0.08, height: 0.04)
let markB = CGRect(x: 0.75, y: 0.40, width: 0.08, height: 0.04)
require(persistence.update([markA], at: 20.0).isEmpty, "First frame must not confirm a marker")
require(persistence.update([markA], at: 20.2).isEmpty, "Second frame must not confirm a marker")
let firstConfirmed = persistence.update([markA], at: 20.4)
require(firstConfirmed.count == 1, "Three consecutive samples confirm a marker")
require(persistence.update([markB], at: 20.6).isEmpty, "Distant marker must start new confirmation")
require(persistence.update([markB], at: 20.6).isEmpty, "Repeated timestamp must not count twice")
require(persistence.update([markB], at: 20.8).isEmpty, "Second sample at new location is unconfirmed")
let secondConfirmed = persistence.update([markB], at: 21.0)
require(secondConfirmed.count == 1 && secondConfirmed[0].id != firstConfirmed[0].id,
        "New marker must not inherit old persistent identifier")
require(persistence.update([], at: 21.2).isEmpty, "Missing sample must never output stale target")
let regained = persistence.update([markB], at: 21.4)
require(regained.count == 1 && regained[0].id == secondConfirmed[0].id,
        "A nearby marker retains visual identity after brief occlusion")
require(persistence.update([], at: 21.6).isEmpty, "First missing frame is not rendered")
require(persistence.update([], at: 21.8).isEmpty, "Second missing frame is not rendered")
require(persistence.update([], at: 22.0).isEmpty, "Third missing frame expires the track")
require(persistence.update([markB], at: 22.2).isEmpty,
        "Expired target must be confirmed again before showing")
require(persistence.update([CGRect(x: -0.1, y: 0.4, width: 0.1, height: 0.1)],
                           at: 21.6).isEmpty, "Out-of-bounds coordinates must be discarded")
persistence.reset()
require(persistence.update([markA], at: 30).isEmpty, "Reset removes prior state")
print("StableDetectionFilter verification checks passed")

// Hybrid fusion: color alone or a person alone must never steer in hybrid mode.
let body = CGRect(x: 0.40, y: 0.30, width: 0.20, height: 0.35)
let nameplate = CGRect(x: 0.44, y: 0.68, width: 0.12, height: 0.025)
let fused = HybridTargetFusion.associate(markers: [nameplate], people: [body])
require(fused.count == 1 && fused[0].matchedPersonBox == body, "Link marker to body below it")
require(HybridTargetFusion.associate(markers: [nameplate], people: []).isEmpty, "Color alone is insufficient")
require(HybridTargetFusion.associate(markers: [], people: [body]).isEmpty, "Person alone is insufficient")
let unrelated = CGRect(x: 0.75, y: 0.68, width: 0.1, height: 0.025)
require(HybridTargetFusion.associate(markers: [unrelated], people: [body]).isEmpty, "Reject unrelated color")
let overlappingBody = CGRect(x: 0.41, y: 0.30, width: 0.20, height: 0.35)
require(HybridTargetFusion.associate(markers: [nameplate], people: [body, overlappingBody]).isEmpty,
        "Ambiguous players under one label must not create a target")
require(HybridTargetFusion.associate(markers: [nameplate, nameplate], people: [body]).count == 1,
        "Duplicate name fragments produce one target per body")
let tallPatch = CGRect(x: 0.44, y: 0.68, width: 0.12, height: 0.15)
require(HybridTargetFusion.associate(markers: [tallPatch], people: [body]).isEmpty, "Reject large background color patch")
let rawReport = HumanAnalysis(detections: fused, imageSize: CGSize(width: 1920, height: 1080),
                              capturedAt: 40, milliseconds: 5, error: nil)
let hybridSample = rawReport.trackingSample(colorMode: true, hybridMode: true)
require(hybridSample.boxes == [body] && !hybridSample.colorMode, "Steer to body coordinates, not fixed name offset")
let legacySample = rawReport.trackingSample(colorMode: true, hybridMode: false)
require(legacySample.boxes == [nameplate] && legacySample.colorMode, "Preserve explicit color-only mode")
let unverified = HumanAnalysis(detections: [HumanDetection(id: UUID(), box: nameplate, confidence: 1)],
                              imageSize: .zero, capturedAt: 40, milliseconds: 5, error: nil)
require(unverified.trackingSample(colorMode: true, hybridMode: true).boxes.isEmpty, "Defensive control boundary rejects unsupported color")
let failedReport = HumanAnalysis(detections: fused, imageSize: .zero, capturedAt: 40,
                                 milliseconds: 5, error: "Vision failed")
require(failedReport.trackingSample(colorMode: true, hybridMode: true).boxes.isEmpty, "Do not steer on failed analysis")

// The real color detector feeds the same geometry used by fusion.
CVPixelBufferLockBaseAddress(buffer, [])
pixels.initialize(repeating: 0, count: pitch * 128)
for y in 16..<20 {
    for x in 64..<88 {
        pixels[y * pitch + x * 4 + 2] = 255
        pixels[y * pitch + x * 4 + 3] = 255
    }
}
CVPixelBufferUnlockBaseAddress(buffer, [])
let thinMarkers = try ColorTargetDetector.detect(buffer, configuration: ColorTrackingConfiguration())
let fixtureBody = CGRect(x: 0.48, y: 0.40, width: 0.25, height: 0.42)
require(HybridTargetFusion.associate(markers: thinMarkers, people: [fixtureBody]).count == 1,
        "Actual extracted color can link to a body in Vision coordinates")

// Two analyses establish identity; missing evidence produces no stale output.
var hybridPersistence = StableDetectionFilter()
require(hybridPersistence.update([body], at: 50, requiredFrames: 2).isEmpty, "Hybrid requires a second observation")
let confirmedHybrid = hybridPersistence.update([body], at: 50.125, requiredFrames: 2)
require(confirmedHybrid.count == 1, "Hybrid confirmation after two analyses")
require(hybridPersistence.update([], at: 50.25, requiredFrames: 2).isEmpty, "No output during missing evidence")

// Identity survives movement but may not transfer to a different overlapping player.
var identityEngine = TrackingEngine()
var identityConfig = AssistanceConfiguration()
identityConfig.radius = 0.5
identityConfig.pointY = 0.5
let targetID = UUID(), distractorID = UUID()
_ = identityEngine.step(now: 60, armed: true, l2: 0, r2: 0, rawX: 0, rawY: 0, sample: nil, config: identityConfig)
let firstIdentity = TrackingSample(boxes: [body], capturedAt: 60.1, colorMode: false, targetIDs: [targetID])
require(identityEngine.step(now: 60.1, armed: true, l2: 1, r2: 0, rawX: 0, rawY: 0,
                           sample: firstIdentity, config: identityConfig).target != nil, "Acquire confirmed identity")
let movedBody = CGRect(x: 0.63, y: 0.30, width: 0.20, height: 0.35)
let movedIdentity = TrackingSample(boxes: [body, movedBody], capturedAt: 60.2, colorMode: false,
                                   targetIDs: [distractorID, targetID])
let movedOutput = identityEngine.step(now: 60.2, armed: true, l2: 1, r2: 0, rawX: 0, rawY: 0,
                                     sample: movedIdentity, config: identityConfig)
require(movedOutput.target != nil && abs(movedOutput.target!.x - 0.73) < 0.0001,
        "Confirmed ID follows motion instead of switching to a closer player")
let replacement = TrackingSample(boxes: [movedBody], capturedAt: 60.3, colorMode: false, targetIDs: [distractorID])
require(identityEngine.step(now: 60.3, armed: true, l2: 1, r2: 0, rawX: 0, rawY: 0,
                           sample: replacement, config: identityConfig).target == nil,
        "Identical geometry with different identity must not inherit the lock")
print("Hybrid fusion and identity checks passed")

var crossingFilter = StableDetectionFilter()
let crossingA = CGRect(x: 0.40, y: 0.30, width: 0.20, height: 0.35)
let crossingB = CGRect(x: 0.46, y: 0.30, width: 0.20, height: 0.35)
_ = crossingFilter.update([crossingA, crossingB], at: 70, requiredFrames: 2)
require(crossingFilter.update([crossingA, crossingB], at: 70.125, requiredFrames: 2).count == 2,
        "Separate bodies can establish independent identities")
let crossingMiddle = CGRect(x: 0.43, y: 0.30, width: 0.20, height: 0.35)
require(crossingFilter.update([crossingMiddle], at: 70.25, requiredFrames: 2).isEmpty,
        "An ambiguous crossing must not inherit either established identity")
print("Ambiguous temporal association check passed")

// Sticky confirmed target remains eligible outside the initial acquisition radius.
var fastEngine = TrackingEngine()
var fastConfig = AssistanceConfiguration()
fastConfig.radius = 0.22
fastConfig.pointY = 0.5
fastConfig.switchOnLoss = true
fastConfig.lossDelay = 0.15
let fastID = UUID(), nextID = UUID()
let initial = CGRect(x: 0.52, y: 0.28, width: 0.08, height: 0.32)
let moved = CGRect(x: 0.77, y: 0.28, width: 0.08, height: 0.32)
let nearby = CGRect(x: 0.61, y: 0.28, width: 0.10, height: 0.32)
let distant = CGRect(x: 0.26, y: 0.28, width: 0.08, height: 0.32)
func fastStep(_ now: Double, l2: Double = 1,
              boxes: [CGRect], ids: [UUID]) -> AssistanceOutput {
    fastEngine.step(now: now, armed: true, l2: l2, r2: 0, rawX: 0, rawY: 0,
                    sample: TrackingSample(boxes: boxes, capturedAt: now,
                                           colorMode: false, targetIDs: ids),
                    config: fastConfig)
}
_ = fastStep(100, l2: 0, boxes: [], ids: [])
let acquired = fastStep(100.1, boxes: [initial], ids: [fastID])
require(acquired.target != nil, "Fast mode acquires a nearby confirmed player")
let followed = fastStep(100.2, boxes: [moved], ids: [fastID])
require(followed.target != nil && followed.target!.x > 0.8,
        "Confirmed lock persists when moving outside original crosshair radius")
require(fastStep(100.25, boxes: [nearby], ids: [nextID]).target == nil,
        "Do not prematurely jump to different identity before loss timer")
let switchedNear = fastStep(100.39, boxes: [nearby, distant], ids: [nextID, UUID()])
require(switchedNear.target != nil && abs(switchedNear.target!.x - 0.66) < 0.001,
        "Handoff picks nearby verified target instead of another distant screen candidate")
_ = fastStep(100.5, l2: 0, boxes: [], ids: [])
_ = fastStep(101.0, boxes: [initial], ids: [fastID])
let noHandoff = fastStep(101.2, boxes: [distant], ids: [nextID])
require(noHandoff.target == nil, "Avoid selecting a distant target on the lost-player frame")
require(fastStep(101.3, boxes: [distant], ids: [nextID]).target == nil,
        "Unrelated distant target stays blocked until L2 is released")
require(PlayerVisualCues.proximity(for: CGRect(x: 0, y: 0.2, width: 0.1, height: 0.35)) == "قريب جدًا",
        "Large visible bodies are classified as visually close")
require(PlayerVisualCues.proximity(for: CGRect(x: 0, y: 0.2, width: 0.1, height: 0.06)) == "بعيد",
        "Small visible bodies are classified as visually distant")
print("Fast identity retention, near handoff, proximity checks passed")


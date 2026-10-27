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
require(persistence.update([], at: 21.2).isEmpty, "Missing sample revokes confirmation")
require(persistence.update([markB], at: 21.4).isEmpty, "Reappearance starts new confirmation")
require(persistence.update([CGRect(x: -0.1, y: 0.4, width: 0.1, height: 0.1)],
                           at: 21.6).isEmpty, "Out-of-bounds coordinates must be discarded")
persistence.reset()
require(persistence.update([markA], at: 30).isEmpty, "Reset removes prior state")
print("StableDetectionFilter verification checks passed")

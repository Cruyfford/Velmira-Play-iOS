import Foundation

struct AssistanceConfiguration: Codable, Equatable {
    var tracking = true
    var radius = 0.22
    var strength = 1.2
    var maxStick = 0.35
    var deadZone = 0.008
    var response = 0.10
    var manualOverride = 0.45
    var staleAfter = 0.40
    var lossDelay = 0.65
    var switchOnLoss = false
    var invertY = false
    // Point inside a person box, measured from its top left.
    var pointX = 0.5
    var pointY = 0.15
    // Color mode offset from the detected name, as fractions of full video size.
    var colorOffsetX = 0.0
    var colorOffsetY = 0.055
    var quickScope = false
    var scopeDelay = 0.30
    var shotDuration = 0.08
    var silentShot = false
    var switchDelay = 0.12
    var switchDuration = 0.07
    var recoil = false
    var recoilX = 0.0
    var recoilY = 0.08
}

struct TrackingSample {
    let boxes: [CGRect] // Vision normalized coordinates: origin bottom left.
    let capturedAt: TimeInterval
    let colorMode: Bool
    var targetIDs: [UUID]? = nil
}
struct AssistanceOutput {
    var x: Double
    var y: Double
    var fire = false
    var switchWeapon = false
    var target: CGPoint? // Normalized, origin top left.
}

/// Pure controller transform. It never changes the physical input state.
struct TrackingEngine {
    private var previousL2 = false
    private var previousR2 = false
    private var scopeStarted: TimeInterval?
    private var swapAt: TimeInterval?
    private var quickFired = false
    private var locked: CGRect?
    private var lockedID: UUID?
    private var lastSeen: TimeInterval = 0
    private var blockedUntilRelease = false
    private var previousTick: TimeInterval?
    private var smoothX = 0.0
    private var smoothY = 0.0
    private var mustRelease = true

    mutating func reset() { self = TrackingEngine() }
    private func clamp(_ x: Double, _ a: Double = -1, _ b: Double = 1) -> Double { min(b, max(a, x)) }
    private func point(_ box: CGRect, _ color: Bool, _ c: AssistanceConfiguration) -> CGPoint {
        if color {
            return CGPoint(x: clamp(box.midX + c.colorOffsetX, 0, 1),
                           y: clamp(1 - box.midY + c.colorOffsetY, 0, 1))
        }
        return CGPoint(x: box.minX + box.width * clamp(c.pointX, 0, 1),
                       y: 1 - box.maxY + box.height * clamp(c.pointY, 0, 1))
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        if i.isNull { return 0 }
        let area = i.width * i.height
        return area / max(0.000001, a.width * a.height + b.width * b.height - area)
    }

    mutating func step(now: TimeInterval, armed: Bool, l2: Double, r2: Double,
                       rawX: Double, rawY: Double, sample: TrackingSample?,
                       config c: AssistanceConfiguration) -> AssistanceOutput {
        var out = AssistanceOutput(x: clamp(rawX), y: clamp(rawY))
        guard armed else { reset(); return out }
        let aim = l2 >= 0.5, shoot = r2 >= 0.5
        if mustRelease {
            if !aim && !shoot { mustRelease = false }
            return out
        }
        defer { previousL2 = aim; previousR2 = shoot; previousTick = now }
        guard aim else {
            locked = nil; lockedID = nil; blockedUntilRelease = false; scopeStarted = nil; swapAt = nil
            quickFired = false; smoothX = 0; smoothY = 0
            return out
        }
        if !previousL2 {
            scopeStarted = c.quickScope ? now : nil
            quickFired = false
        }
        if !c.quickScope { scopeStarted = nil }
        if !c.silentShot { swapAt = nil }
        if c.silentShot && shoot && !previousR2 { swapAt = now + clamp(c.switchDelay, 0.03, 1) }
        if let start = scopeStarted {
            let fireStart = start + clamp(c.scopeDelay, 0.05, 2)
            let fireEnd = fireStart + clamp(c.shotDuration, 0.03, 0.3)
            if now >= fireStart && now < fireEnd {
                out.fire = true
                if !quickFired {
                    quickFired = true
                    if c.silentShot { swapAt = now + clamp(c.switchDelay, 0.03, 1) }
                }
            }
        }
        if let swap = swapAt {
            out.switchWeapon = now >= swap && now < swap + clamp(c.switchDuration, 0.03, 0.3)
            if now >= swap + clamp(c.switchDuration, 0.03, 0.3) { swapAt = nil }
        }
        let manual = hypot(rawX, rawY) >= clamp(c.manualOverride, 0.1, 1)
        if c.tracking && !manual && !blockedUntilRelease,
           let sample, now >= sample.capturedAt, now - sample.capturedAt <= clamp(c.staleAfter, 0.1, 0.8) {
            let center = CGPoint(x: 0.5, y: 0.5)
            // A locked, verified target stays eligible even when it moves
            // outside the initial near-crosshair acquisition circle.
            let visible = sample.boxes.indices.filter { index in
                let box = sample.boxes[index]
                return !box.isNull && box.width > 0 && box.height > 0 &&
                    box.minX.isFinite && box.maxX.isFinite &&
                    box.minY.isFinite && box.maxY.isFinite &&
                    box.minX >= 0 && box.minY >= 0 &&
                    box.maxX <= 1 && box.maxY <= 1
            }
            let acquisition = visible.filter {
                distance(point(sample.boxes[$0], sample.colorMode, c), center) <=
                    clamp(c.radius, 0.05, 0.5)
            }
            func identity(_ index: Int) -> UUID? {
                guard let ids = sample.targetIDs, ids.count == sample.boxes.count else { return nil }
                return ids[index]
            }
            var selected: Int?
            let hadLock = locked != nil
            if let prior = locked {
                if let lockedID {
                    selected = visible.first { identity($0) == lockedID }
                } else {
                    // Older color-only detection has no stable IDs.
                    selected = visible.filter { overlap(prior, sample.boxes[$0]) >= 0.12 }
                        .max { overlap(prior, sample.boxes[$0]) < overlap(prior, sample.boxes[$1]) }
                }
                if selected == nil && now - lastSeen >= clamp(c.lossDelay, 0.05, 2) {
                    // Lost identity is not proof of an elimination.
                    if c.switchOnLoss {
                        // Prefer another confirmed player close to the last
                        // location, not an arbitrary distant screen candidate.
                        let lastPosition = point(prior, sample.colorMode, c)
                        let handoffRadius = clamp(c.radius, 0.12, 0.28)
                        selected = visible.filter {
                            distance(point(sample.boxes[$0], sample.colorMode, c),
                                     lastPosition) <= handoffRadius
                        }.min {
                            distance(point(sample.boxes[$0], sample.colorMode, c), lastPosition) <
                                distance(point(sample.boxes[$1], sample.colorMode, c), lastPosition)
                        }
                        // Keep the last identity/location while waiting for a
                        // nearby fresh candidate. Missing targets never emit input.
                    } else {
                        locked = nil
                        lockedID = nil
                        blockedUntilRelease = true
                    }
                }
            }
            if !hadLock && !blockedUntilRelease {
                selected = acquisition.min {
                    distance(point(sample.boxes[$0], sample.colorMode, c), center) <
                        distance(point(sample.boxes[$1], sample.colorMode, c), center)
                }
            }
            if let selected {
                let box = sample.boxes[selected]
                if let oldID = lockedID, oldID != identity(selected) {
                    smoothX = 0; smoothY = 0
                }
                locked = box; lockedID = identity(selected); lastSeen = sample.capturedAt
                let target = point(box, sample.colorMode, c)
                out.target = target
                let dx = target.x - 0.5, dy = target.y - 0.5
                let cap = clamp(c.maxStick, 0.02, 0.8)
                let desiredX = abs(dx) < c.deadZone ? 0 : clamp(dx * clamp(c.strength, 0.1, 5), -cap, cap)
                let desiredY = abs(dy) < c.deadZone ? 0 : clamp(dy * clamp(c.strength, 0.1, 5), -cap, cap) * (c.invertY ? -1 : 1)
                let dt = clamp(now - (previousTick ?? now - 1 / 60), 0, 0.1)
                let alpha = 1 - exp(-dt / clamp(c.response, 0.02, 0.5))
                // Brake immediately at the aim point or after crossing it.
                // Otherwise smoothing can continue pushing away from the target.
                if desiredX == 0 || smoothX * desiredX < 0 { smoothX = 0 }
                if desiredY == 0 || smoothY * desiredY < 0 { smoothY = 0 }
                smoothX += (desiredX - smoothX) * alpha
                smoothY += (desiredY - smoothY) * alpha
                out.x += smoothX; out.y += smoothY
            } else { smoothX = 0; smoothY = 0 }
        } else {
            smoothX = 0; smoothY = 0
            if manual { locked = nil; lockedID = nil }
        }
        if c.recoil && (shoot || out.fire) && !manual {
            out.x += clamp(c.recoilX, -0.3, 0.3)
            out.y += clamp(c.recoilY, -0.3, 0.3)
        }
        out.x = clamp(out.x); out.y = clamp(out.y)
        return out
    }
}

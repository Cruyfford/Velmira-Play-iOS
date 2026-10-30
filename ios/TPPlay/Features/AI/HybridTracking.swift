import Foundation

struct HumanDetection: Identifiable, Sendable {
    let id: UUID
    let box: CGRect
    let confidence: Float
    /// Additional human-rectangle evidence, not a calibrated accuracy score.
    var humanSupported = false
    /// An optional person rectangle linked visually to a colored nameplate.
    /// Missing or ambiguous associations must not create a body-point marker.
    var matchedPersonBox: CGRect? = nil
}
/// Pairs a colored player name with a visible body for overlay and hybrid control.
/// Missing/ambiguous evidence produces no automatic body marker.
enum VisualBodyAssociation {
    static func bestPerson(for name: CGRect, among people: [CGRect]) -> CGRect? {
        guard name.width > 0, name.height > 0 else { return nil }
        let options: [(rect: CGRect, score: CGFloat)] = people.compactMap { body in
            guard body.width >= 0.015, body.height >= 0.055,
                  body.minX >= 0, body.minY >= 0,
                  body.maxX <= 1, body.maxY <= 1 else { return nil }
            let toleranceX = max(0.02, min(0.06, body.width * 0.3))
            guard name.midX >= body.minX - toleranceX,
                  name.midX <= body.maxX + toleranceX else { return nil }
            let verticalGap = name.minY - body.maxY
            let allowableGap = max(0.035, min(0.12, body.height * 0.6))
            let allowableOverlap = max(0.018, min(0.045, body.height * 0.15))
            guard verticalGap >= -allowableOverlap,
                  verticalGap <= allowableGap else { return nil }
            let xError = abs(name.midX - body.midX) / max(0.025, body.width)
            let yError = abs(verticalGap) / max(0.025, allowableGap)
            return (body, xError + yError * 0.65)
        }.sorted { $0.score < $1.score }
        guard let best = options.first else { return nil }
        // Reject two similarly plausible players under the same colored name.
        if options.count > 1 && options[1].score - best.score < 0.28 { return nil }
        return best.rect
    }

    /// Selected relative body location, automatically scaling with visible size.
    /// Returns top-left normalized video coordinates for SwiftUI display.
    static func selectedPoint(in body: CGRect, x: Double, y: Double) -> CGPoint {
        let px = CGFloat(min(1, max(0, x)))
        let py = CGFloat(min(1, max(0, y)))
        return CGPoint(x: body.minX + body.width * px,
                       y: 1 - body.maxY + body.height * py)
    }
}

struct HumanAnalysis: Sendable {
    let detections: [HumanDetection]
    let imageSize: CGSize
    let capturedAt: TimeInterval
    let milliseconds: Double
    let error: String?
    /// Fresh Vision person rectangles used only for green visual overlays.
    /// These are potential players (including allies), not enemy confirmations.
    var visiblePlayerBoxes: [CGRect] = []

    func trackingSample(colorMode: Bool, hybridMode: Bool) -> TrackingSample {
        guard error == nil else {
            return TrackingSample(boxes: [], capturedAt: capturedAt, colorMode: false)
        }
        if colorMode && hybridMode {
            // Never fall back to a name offset or an unrelated human rectangle.
            let supported = detections.filter { $0.humanSupported && $0.matchedPersonBox != nil }
            return TrackingSample(boxes: supported.compactMap(\.matchedPersonBox),
                                  capturedAt: capturedAt, colorMode: false,
                                  targetIDs: supported.map(\.id))
        }
        // Legacy modes retain overlap-based locking when precision filtering is off.
        return TrackingSample(boxes: detections.map(\.box), capturedAt: capturedAt, colorMode: colorMode)
    }
}

/// Color supplies the user-selected team cue; Vision supplies body geometry.
/// Neither is proof of team identity. No observation survives a missing cue.
enum HybridTargetFusion {
    static func associate(markers: [CGRect], people: [CGRect]) -> [HumanDetection] {
        var groups: [(body: CGRect, markers: [CGRect])] = []
        for marker in markers {
            guard marker.minX.isFinite, marker.minY.isFinite,
                  marker.width.isFinite, marker.height.isFinite,
                  marker.minX >= 0, marker.minY >= 0, marker.maxX <= 1, marker.maxY <= 1,
                  marker.width >= 0.004, marker.width <= 0.45,
                  marker.height > 0, marker.height <= 0.075,
                  marker.width >= marker.height,
                  let body = VisualBodyAssociation.bestPerson(for: marker, among: people) else { continue }
            if let index = groups.firstIndex(where: { $0.body == body }) {
                groups[index].markers.append(marker)
            } else {
                groups.append((body, [marker]))
            }
        }
        return groups.compactMap { group in
            // Several connected letter fragments may describe one name. Merge
            // only a compact horizontal label, and emit at most one body target.
            let marker = group.markers.dropFirst().reduce(group.markers[0]) { $0.union($1) }
            guard marker.width <= min(0.45, group.body.width * 2.5),
                  marker.height <= 0.075 else { return nil }
            return HumanDetection(id: UUID(), box: marker, confidence: 0,
                                  humanSupported: true, matchedPersonBox: group.body)
        }
    }
}


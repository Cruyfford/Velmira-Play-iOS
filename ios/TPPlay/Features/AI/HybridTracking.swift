import Foundation

enum RosterSide: String, CaseIterable, Identifiable, Codable, Sendable {
    case unknown = "غير مصنف", friendly = "فريقي", opponent = "الخصوم"
    var id: String { rawValue }
}


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
    /// nil means no HUD text check was performed on this frame.
    /// A detected HUD cue is not definitive proof about a specific player.
    var eliminationCue: Bool? = nil

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



/// HUD text and box-size heuristics. No metric distance or confirmed death data
/// comes from Remote Play; these are visual, best-effort annotations only.
enum PlayerVisualCues {
    static func proximity(for box: CGRect) -> String {
        if box.height >= 0.30 { return "قريب جدًا" }
        if box.height >= 0.17 { return "قريب" }
        if box.height >= 0.09 { return "متوسط" }
        return "بعيد"
    }

    static func showsEliminationNotice(_ rawText: String) -> Bool {
        let t = rawText.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid 'KILLS', scoreboard columns, players' names, and killstreak text.
        return t.hasPrefix("KILLED:") ||
               t.hasPrefix("KILLED ") ||
               t == "ELIMINATED" ||
               t.hasPrefix("ELIMINATED ") ||
               t == "ELIMINATION" ||
               t.hasPrefix("ELIMINATION ")
    }

    static func sameVisiblePlayer(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull { return false }
        let union = a.width * a.height + b.width * b.height -
            intersection.width * intersection.height
        return union > 0 && intersection.width * intersection.height / union >= 0.30
    }
}


// Optional identity data derived from on-screen gamer tags. Text recognition
// and person detection are independent; only a spatially unambiguous exact
// roster match is allowed to label a YOLO box.
struct NameplateTextObservation: Sendable {
    let text: String
    let box: CGRect     // Normalized bottom-left origin, same as YOLO
    let confidence: Float
}
struct KnownRosterPlayer: Sendable {
    let name: String
    let side: RosterSide
}
struct LiveNameMatch: Sendable {
    let name: String
    let side: RosterSide
    let body: CGRect
    let capturedAt: TimeInterval
}
enum NameplateRosterAssociation {
    // Only normalized exact matches, or a uniquely identifying stripped
    // Activision discriminator (#digits) / clan tag alias. Never fuzzy-guess
    // "0" vs "O", and never use mere substring containment.
    private static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        })
    }
    private static func shortName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "[", let closing = value.firstIndex(of: "]") {
            value = String(value[value.index(after: closing)...])
        }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        return normalized(value)
    }
    static func match(
        texts: [NameplateTextObservation],
        bodies: [CGRect],
        players: [KnownRosterPlayer],
        capturedAt: TimeInterval
    ) -> [LiveNameMatch] {
        guard capturedAt.isFinite, !texts.isEmpty, !bodies.isEmpty, !players.isEmpty else { return [] }
        var namesUsed = Set<String>()
        var bodiesUsed = Set<Int>()
        var result = [LiveNameMatch]()
        // Strongest OCR text first, so overlapping text alternatives cannot
        // attach two different labels to the same on-screen body.
        for text in texts.sorted(by: { $0.confidence > $1.confidence }) {
            guard text.confidence >= 0.56, text.box.width > 0,
                  text.box.height > 0, text.box.minX >= 0,
                  text.box.minY >= 0, text.box.maxX <= 1,
                  text.box.maxY <= 1 else { continue }
            let exact = normalized(text.text)
            let matching = players.filter {
                $0.side != .unknown &&
                (normalized($0.name) == exact ||
                 (exact.count >= 5 && shortName($0.name) == shortName(text.text) &&
                  shortName(text.text).count >= 5))
            }
            // Require a unique *name and team*; distinct discriminator IDs
            // with the same displayed handle remain ambiguous.
            guard matching.count == 1, let entry = matching.first,
                  !namesUsed.contains(normalized(entry.name)),
                  let body = VisualBodyAssociation.bestPerson(for: text.box, among: bodies),
                  let bodyIndex = bodies.firstIndex(of: body),
                  bodiesUsed.insert(bodyIndex).inserted else { continue }
            namesUsed.insert(normalized(entry.name))
            result.append(LiveNameMatch(name: entry.name, side: entry.side,
                                        body: body, capturedAt: capturedAt))
        }
        return result
    }
    static func matchingBox(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull { return false }
        let area = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - area
        return union > 0 && area / union >= 0.22
    }
}

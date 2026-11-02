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

/// UI-only cache to prevent player outlines blinking on a single missed YOLO
/// inference. Its output must never be used for target acquisition or control.
struct PlayerOverlayBoxHold {
    private var boxes: [CGRect] = []
    private var lastPositiveAt: TimeInterval = -.infinity

    mutating func accept(_ candidates: [CGRect], capturedAt: TimeInterval,
                         hasError: Bool = false) -> [CGRect] {
        guard !hasError, capturedAt.isFinite else { reset(); return [] }
        let valid = candidates.filter {
            $0.minX.isFinite && $0.minY.isFinite &&
            $0.width.isFinite && $0.height.isFinite &&
            $0.minX >= 0 && $0.minY >= 0 &&
            $0.maxX <= 1 && $0.maxY <= 1 &&
            $0.width > 0 && $0.height > 0
        }
        if !valid.isEmpty {
            boxes = valid
            lastPositiveAt = capturedAt
            return valid
        }
        // Up to ~450 ms of visual continuity only; an expired/missing YOLO
        // result still means zero valid targets for TeamTargetSafety.
        if capturedAt >= lastPositiveAt && capturedAt - lastPositiveAt <= 0.45 {
            return boxes
        }
        reset()
        return []
    }

    mutating func reset() {
        boxes.removeAll()
        lastPositiveAt = -.infinity
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


/// Optional smart-color selection: a color patch must be attached to a
/// visible YOLO person, never to a free-standing Point, Mark, A/B HUD icon.
/// A geometric association does NOT establish enemy team identity: that remains
/// the responsibility of TeamTargetSafety and confirmed roster names.
enum SmartColorBodyGate {
    static func associatedBodies(markers: [CGRect], people: [CGRect]) -> [CGRect] {
        HybridTargetFusion.associate(markers: markers, people: people)
            .compactMap(\.matchedPersonBox)
    }

    static func permits(_ body: CGRect, matchedBodies: [CGRect]) -> Bool {
        // Exact YOLO geometry prevents a neighboring player from inheriting a
        // colored marker during overlap. Fusion already rejects ambiguity.
        matchedBodies.contains(body)
    }
}

/// Safety boundary between visual YOLO detections and controller movement.
/// YOLO's single "Enemy" class is *not* proof a person is on the other team.
/// The conservative default permits ONLY bodies with a recent twice-confirmed
/// overhead gamer tag which still belongs to the currently saved opponent roster.
/// Unknown, friendly, ambiguous, stale, or duplicate associations cannot steer.
enum TeamTargetSafety {
    static func trackingSample(
        from analysis: HumanAnalysis,
        names: [LiveNameMatch],
        roster: [KnownRosterPlayer],
        now: TimeInterval,
        requireConfirmedOpponent: Bool = true
    ) -> TrackingSample {
        let empty = TrackingSample(boxes: [], capturedAt: analysis.capturedAt,
                                   colorMode: false, targetIDs: [])
        guard analysis.error == nil, now.isFinite, analysis.capturedAt.isFinite,
              now >= analysis.capturedAt, now - analysis.capturedAt <= 0.8 else {
            return empty
        }
        let eligible = analysis.detections.filter {
            $0.humanSupported && $0.matchedPersonBox != nil
        }
        guard !eligible.isEmpty else { return empty }

        // Once the scoreboard is edited or the match changes, old identity
        // observations must not authorize targets in the new roster.
        let freshNames = names.filter { item in
            guard item.capturedAt.isFinite,
                  now >= item.capturedAt, now - item.capturedAt <= 1.55,
                  item.capturedAt <= analysis.capturedAt + 0.12 else { return false }
            return roster.contains {
                $0.side == item.side &&
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) ==
                item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            }
        }

        var boxes: [CGRect] = []
        var ids: [UUID] = []
        for person in eligible {
            guard let body = person.matchedPersonBox else { continue }
            let labels = freshNames.filter {
                NameplateRosterAssociation.matchingBox(body, $0.body)
            }
            // Reject any friendlies and any conflicting or duplicate
            // annotations. Unknown people do not become enemies by default.
            guard !labels.contains(where: { $0.side == .friendly }),
                  labels.count <= 1 else { continue }
            if requireConfirmedOpponent {
                guard let label = labels.first, label.side == .opponent else {
                    continue
                }
                // If the same name could belong to two overlapping YOLO boxes,
                // neither is a safe automatic target.
                let contenders = eligible.filter {
                    guard let other = $0.matchedPersonBox else { return false }
                    return NameplateRosterAssociation.matchingBox(other, label.body)
                }
                guard contenders.count == 1 else { continue }
            }
            boxes.append(body)
            ids.append(person.id)
        }
        return TrackingSample(boxes: boxes, capturedAt: analysis.capturedAt,
                              colorMode: false, targetIDs: ids)
    }
}

/// Analysis rate cap based on averaged on-device inference time and thermal pressure.
enum AdaptiveAnalysisBudget {
    enum Heat: Int { case nominal = 0, fair = 1, serious = 2, critical = 3 }
    static func level(_ thermal: ProcessInfo.ThermalState) -> Heat {
        switch thermal {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }
    static func limit(requested: Double, averageInferenceMS: Double, thermalLevel: Heat) -> Double {
        guard requested.isFinite, requested > 0 else { return 1 }
        var limited = min(24, max(1, requested))
        if averageInferenceMS.isFinite && averageInferenceMS > 1 {
            limited = min(limited, max(1, 700 / averageInferenceMS))
        }
        switch thermalLevel {
        case .nominal: break
        case .fair: limited = min(limited, 10)
        case .serious: limited = min(limited, 3)
        case .critical: limited = min(limited, 1)
        }
        return max(1, limited)
    }
}

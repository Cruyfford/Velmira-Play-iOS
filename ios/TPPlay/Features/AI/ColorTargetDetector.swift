import Foundation
import CoreVideo

struct ColorTrackingConfiguration: Sendable {
    var hue = 0.0
    var tolerance = 0.045
    var minimumSaturation = 0.65
    var minimumBrightness = 0.45
}

/// Reads video rows directly so color boxes share Vision's normalized coordinates.
/// Small bright objects matching a chosen hue are candidates, not confirmed enemies.
enum ColorTargetDetector {
    static func detect(_ buffer: CVPixelBuffer, configuration c: ColorTrackingConfiguration) throws -> [CGRect] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let planar = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || pixelFormat == kCVPixelFormatType_32BGRA else {
            throw NSError(domain: "VelmiraColor", code: 1, userInfo: [NSLocalizedDescriptionKey: "صيغة الفيديو غير مدعومة في وضع اللون"])
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = max(1, w / 320)
        let cols = max(1, w / stride), rows = max(1, h / stride)
        let count = cols * rows
        var mask = [Bool](repeating: false, count: count)
        let yBase = (planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer))?.assumingMemoryBound(to: UInt8.self)
        let uvBase = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) : nil
        let yPitch = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let uvPitch = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) : 0
        guard let yBase, !planar || uvBase != nil else { return [] }
        for row in 0..<rows {
            for col in 0..<cols {
                let x = col * stride, y = row * stride
                let r: Double, g: Double, b: Double
                if planar, let uvBase {
                    let full = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    let luminance = (Double(yBase[y * yPitch + x]) - (full ? 0 : 16)) * (full ? 1 : 255 / 219)
                    let uv = (y / 2) * uvPitch + (x / 2) * 2
                    let cb = (Double(uvBase[uv]) - 128) * (full ? 1 : 255 / 224)
                    let cr = (Double(uvBase[uv + 1]) - 128) * (full ? 1 : 255 / 224)
                    r = min(255, max(0, luminance + 1.5748 * cr)) / 255
                    g = min(255, max(0, luminance - 0.1873 * cb - 0.4681 * cr)) / 255
                    b = min(255, max(0, luminance + 1.8556 * cb)) / 255
                } else {
                    let offset = y * yPitch + x * 4
                    b = Double(yBase[offset]) / 255; g = Double(yBase[offset + 1]) / 255; r = Double(yBase[offset + 2]) / 255
                }
                let high = max(r, max(g, b)), low = min(r, min(g, b)), delta = high - low
                guard high >= c.minimumBrightness, delta > 0.001, delta / high >= c.minimumSaturation else { continue }
                var hue: Double
                if high == r { hue = (g - b) / delta / 6 }
                else if high == g { hue = ((b - r) / delta + 2) / 6 }
                else { hue = ((r - g) / delta + 4) / 6 }
                if hue < 0 { hue += 1 }
                let difference = abs(hue - c.hue)
                mask[row * cols + col] = min(difference, 1 - difference) <= c.tolerance
            }
        }
        var visited = [Bool](repeating: false, count: count)
        var boxes: [CGRect] = []
        for start in 0..<count where mask[start] && !visited[start] {
            var queue = [start], head = 0
            visited[start] = true
            var minX = start % cols, maxX = minX, minY = start / cols, maxY = minY
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % cols, y = i / cols
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                // Join small gaps between letters of a nameplate.
                for dy in -1...1 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0 && nx < cols && ny >= 0 && ny < rows else { continue }
                        let next = ny * cols + nx
                        if mask[next] && !visited[next] { visited[next] = true; queue.append(next) }
                    }
                }
            }
            guard queue.count >= 3, queue.count <= count / 12 else { continue }
            boxes.append(CGRect(x: Double(minX) / Double(cols),
                                y: 1 - Double(maxY + 1) / Double(rows),
                                width: Double(maxX - minX + 1) / Double(cols),
                                height: Double(maxY - minY + 1) / Double(rows)))
        }
        return Array(boxes.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(64))
    }
}


/// Conservative multi-frame confirmation for image detections.
/// A stable marker does not prove that it is an enemy or that accuracy is 99%.
struct StableDetectionFilter {
    struct Verified {
        let index: Int
        let id: UUID
    }

    private struct Track {
        let id: UUID
        let box: CGRect
        let hits: Int
        let missedFrames: Int
    }

    private var tracks: [Track] = []
    private var previousTimestamp: TimeInterval?

    mutating func reset() {
        tracks.removeAll()
        previousTimestamp = nil
    }

    mutating func update(_ boxes: [CGRect], at timestamp: TimeInterval, requiredFrames: Int = 3) -> [Verified] {
        guard timestamp.isFinite, requiredFrames > 0 else { reset(); return [] }
        if let previousTimestamp {
            guard timestamp > previousTimestamp else { return [] }
            if timestamp - previousTimestamp > 0.85 { tracks.removeAll() }
        }
        previousTimestamp = timestamp

        var available = Set(tracks.indices)
        var next: [Track] = []
        var verified: [Verified] = []
        for (index, box) in boxes.enumerated() {
            guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite,
                  box.width > 0, box.height > 0,
                  box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1 else { continue }
            let best = available.compactMap { i -> (Int, CGFloat)? in
                let old = tracks[i].box
                let dx = abs(old.midX - box.midX)
                let dy = abs(old.midY - box.midY)
                let limitX = max(0.025, min(0.10, max(old.width, box.width) * 1.0))
                let limitY = max(0.02, min(0.09, max(old.height, box.height) * 1.0))
                let ratio = (box.width * box.height) / (old.width * old.height)
                guard dx <= limitX, dy <= limitY, ratio >= 0.40, ratio <= 2.5 else { return nil }
                let score = dx / limitX + dy / limitY + abs(1 - ratio) * 0.25
                return (i, score)
            }.min { $0.1 < $1.1 }

            let item: Track
            if let oldIndex = best?.0 {
                available.remove(oldIndex)
                item = Track(id: tracks[oldIndex].id, box: box,
                             hits: min(50, tracks[oldIndex].hits + 1), missedFrames: 0)
            } else {
                item = Track(id: UUID(), box: box, hits: 1, missedFrames: 0)
            }
            next.append(item)
            if item.hits >= requiredFrames { verified.append(Verified(index: index, id: item.id)) }
        }
        // Keep identity for up to two missed analyses without rendering or
        // steering toward an unseen target. If it reappears nearby, regain
        // the same ID. Never return stale detections.
        for i in available {
            let old = tracks[i]
            if old.missedFrames < 2 {
                next.append(Track(id: old.id, box: old.box, hits: old.hits,
                                  missedFrames: old.missedFrames + 1))
            }
        }
        tracks = next
        return verified
    }
}

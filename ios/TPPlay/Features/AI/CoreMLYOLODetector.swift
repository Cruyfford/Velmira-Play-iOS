import Foundation
import CoreML
import CoreVideo
import CoreImage

struct YOLOPersonCandidate {
    let box: CGRect               // normalized, bottom-left origin
    let confidence: Float
}

/// Uses Apple's real YOLOv3 Tiny INT8 Core ML model; never calls Apple Vision.
final class CoreMLYOLODetector {
    static let shared = CoreMLYOLODetector()
    private let model: MLModel?
    private let imageInput: String
    private let imageWidth: Int
    private let imageHeight: Int
    private let loadFailure: String?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        guard let url = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc") else {
            model = nil; imageInput = "image"; imageWidth = 416; imageHeight = 416
            loadFailure = "نموذج YOLO غير موجود في حزمة التطبيق."
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let loaded = try MLModel(contentsOf: url, configuration: config)
            guard let feature = loaded.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
                  let constraint = feature.value.imageConstraint else {
                model = nil; imageInput = "image"; imageWidth = 416; imageHeight = 416
                loadFailure = "صيغة مدخل صورة YOLO غير صحيحة."
                return
            }
            model = loaded; imageInput = feature.key
            imageWidth = constraint.pixelsWide; imageHeight = constraint.pixelsHigh
            loadFailure = nil
        } catch {
            model = nil; imageInput = "image"; imageWidth = 416; imageHeight = 416
            loadFailure = "فشل تحميل YOLO: \(error.localizedDescription)"
        }
    }

    func detect(_ frame: CVPixelBuffer, threshold: Float) throws -> [YOLOPersonCandidate] {
        guard let model else {
            throw NSError(domain: "VelmiraYOLO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: loadFailure ?? "YOLO غير جاهز"])
        }
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(frame))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(frame))
        guard sourceWidth > 0, sourceHeight > 0 else { return [] }
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        let ratio = min(w/sourceWidth, h/sourceHeight)
        let drawnWidth = sourceWidth*ratio, drawnHeight = sourceHeight*ratio
        let offsetX = (w-drawnWidth)/2, offsetY = (h-drawnHeight)/2

        var outputBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let created = CVPixelBufferCreate(kCFAllocatorDefault, imageWidth, imageHeight,
                                          kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                          &outputBuffer)
        guard created == kCVReturnSuccess, let outputBuffer else {
            throw NSError(domain: "VelmiraYOLO", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "تعذر تغيير حجم إطار YOLO"])
        }

        let transformed = CIImage(cvPixelBuffer: frame)
            .transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        context.render(transformed.composited(over: black), to: outputBuffer)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            imageInput: MLFeatureValue(pixelBuffer: outputBuffer)
        ])
        let prediction = try model.prediction(from: input)
        guard let scores = prediction.featureValue(for: "confidence")?.multiArrayValue,
              let coords = prediction.featureValue(for: "coordinates")?.multiArrayValue,
              scores.shape.count == 2, coords.shape.count == 2,
              scores.shape[1].intValue == 80, coords.shape[1].intValue == 4 else {
            throw NSError(domain: "VelmiraYOLO", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "صيغة مخرجات نموذج YOLO غير مدعومة"])
        }

        let count = min(scores.shape[0].intValue, coords.shape[0].intValue)
        var persons = [YOLOPersonCandidate]()
        for i in 0..<count {
            let score = scores[[NSNumber(value: i), 0]].floatValue
            guard score.isFinite, score >= threshold else { continue }
            let cx = coords[[NSNumber(value: i), 0]].doubleValue
            let cy = coords[[NSNumber(value: i), 1]].doubleValue
            let bw = coords[[NSNumber(value: i), 2]].doubleValue
            let bh = coords[[NSNumber(value: i), 3]].doubleValue
            guard cx.isFinite, cy.isFinite, bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { continue }

            // Apple model returns normalized xywh; unletterbox and flip Y to
            // match the bottom-left coordinates used by the tracking engine.
            let x0 = ((cx-bw/2)*Double(w)-Double(offsetX))/Double(drawnWidth)
            let x1 = ((cx+bw/2)*Double(w)-Double(offsetX))/Double(drawnWidth)
            let yTop = ((cy-bh/2)*Double(h)-Double(offsetY))/Double(drawnHeight)
            let yBottom = ((cy+bh/2)*Double(h)-Double(offsetY))/Double(drawnHeight)
            let left = max(0, min(1, x0)), right = max(0, min(1, x1))
            let bottom = max(0, min(1, 1-yBottom)), top = max(0, min(1, 1-yTop))
            guard right-left >= 0.01, top-bottom >= 0.04 else { continue }
            persons.append(YOLOPersonCandidate(
                box: CGRect(x: left, y: bottom, width: right-left, height: top-bottom),
                confidence: score))
        }
        persons.sort { $0.confidence > $1.confidence }
        var filtered = [YOLOPersonCandidate]()
        for person in persons {
            if filtered.allSatisfy({ Self.overlap($0.box, person.box) < 0.45 }) {
                filtered.append(person)
                if filtered.count >= 24 { break }
            }
        }
        return filtered
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b)
        if rect.isNull { return 0 }
        let area = rect.width*rect.height
        let union = a.width*a.height+b.width*b.height-area
        return union > 0 ? area/union : 0
    }
}

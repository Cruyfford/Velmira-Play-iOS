import Foundation
import CoreML
import CoreVideo
import CoreImage

struct YOLOPersonCandidate {
    let box: CGRect  // Normalized rectangle, bottom-left origin (Vision-style geometry).
    let confidence: Float
}

/// MWIII training experiment: a one-class YOLOv8n Core ML MLProgram.
/// The model package is intentionally NOT committed to the public repository.
/// It is bundled in the locally packaged IPA or copied by the local build script.
/// No Apple Vision or legacy YOLOv3 decoding fallback is used.
final class CoreMLYOLODetector: @unchecked Sendable {
    // Calls are serialized by AIFrameAnalyzer's dedicated serial queue.
    static let shared = CoreMLYOLODetector()
    private let model: MLModel?
    private let imageInput: String
    private let imageWidth: Int
    private let imageHeight: Int
    private let loadFailure: String?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        do {
            let fm = FileManager.default
            let compiled: URL
            // Some resigning tools and source-only CI builds produce a bundle where
            // Bundle.url(forResource:) cannot discover the raw .mlpackage directory.
            // Look at the actual signed application root too, and verify the weights
            // before attempting a potentially expensive Core ML compilation.
            let bundleRoots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
            let packagePaths = bundleRoots.map {
                $0.appendingPathComponent("VelmiraMW3.mlpackage", isDirectory: true)
            }
            let weightsRelativePath = "Data/com.apple.CoreML/weights/weight.bin"
            func validSourcePackage(_ candidate: URL) -> Bool {
                let manifest = candidate.appendingPathComponent("Manifest.json")
                let modelDefinition = candidate.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
                let weights = candidate.appendingPathComponent(weightsRelativePath)
                guard fm.fileExists(atPath: manifest.path),
                      fm.fileExists(atPath: modelDefinition.path),
                      let size = (try? fm.attributesOfItem(atPath: weights.path))?[.size] as? NSNumber
                else { return false }
                return size.int64Value > 1_000_000
            }
            let discoveredSource = packagePaths.first(where: validSourcePackage)
                ?? Bundle.main.url(forResource: "VelmiraMW3", withExtension: "mlpackage")
                    .flatMap { validSourcePackage($0) ? $0 : nil }
            let bundledCompiled = Bundle.main.url(forResource: "VelmiraMW3", withExtension: "mlmodelc")
                ?? bundleRoots.map {
                    $0.appendingPathComponent("VelmiraMW3.mlmodelc", isDirectory: true)
                }.first(where: { fm.fileExists(atPath: $0.path) })
            if let packaged = bundledCompiled {
                compiled = packaged
            } else if let source = discoveredSource {
                // The signed IPA contains the original 640px model and its weights.
                // Compile once on the analyzer's worker queue, then cache it.
                let support = try fm.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask, appropriateFor: nil, create: true)
                let cached = support.appendingPathComponent("VelmiraMW3-yolov8n-640-v2.mlmodelc")
                if fm.fileExists(atPath: cached.path) {
                    compiled = cached
                } else {
                    let temporary = try MLModel.compileModel(at: source)
                    try fm.moveItem(at: temporary, to: cached)
                    compiled = cached
                }
            } else {
                let incomplete = packagePaths.contains { fm.fileExists(atPath: $0.path) }
                throw NSError(domain: "VelmiraYOLO", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: incomplete
                                ? "حزمة VelmiraMW3.mlpackage موجودة لكنها ناقصة أو بدون أوزان weight.bin. ثبّت IPA الكامل بعد توقيعه."
                                : "نموذج VelmiraMW3.mlpackage غير موجود داخل التطبيق. نسخة GitHub Actions المصدرية لا تحتوي الأوزان؛ ثبّت IPA الكامل."])
            }

            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = try MLModel(contentsOf: compiled, configuration: configuration)
            guard let input = loaded.modelDescription.inputDescriptionsByName.first(where: {
                $0.value.type == .image
            }), let constraint = input.value.imageConstraint else {
                throw NSError(domain: "VelmiraYOLO", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "YOLO لا يحتوي مدخل صورة صالحاً."])
            }
            guard constraint.pixelsWide == 640 && constraint.pixelsHigh == 640,
                  let output = loaded.modelDescription.outputDescriptionsByName["var_910"],
                  output.type == .multiArray else {
                throw NSError(domain: "VelmiraYOLO", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                "هذا ليس نموذج MW3 YOLOv8n المتدرّب (640px / var_910)."])
            }
            model = loaded
            imageInput = input.key
            imageWidth = constraint.pixelsWide
            imageHeight = constraint.pixelsHigh
            loadFailure = nil
        } catch {
            model = nil
            imageInput = "image"
            imageWidth = 640
            imageHeight = 640
            loadFailure = "تعذر تشغيل YOLOv8 المدرب: \(error.localizedDescription)"
        }
    }

    func detect(_ frame: CVPixelBuffer, threshold: Float) throws -> [YOLOPersonCandidate] {
        guard let model else {
            throw NSError(domain: "VelmiraYOLO", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: loadFailure ?? "نموذج YOLO غير متوفر"])
        }
        let originalWidth = CGFloat(CVPixelBufferGetWidth(frame))
        let originalHeight = CGFloat(CVPixelBufferGetHeight(frame))
        guard originalWidth > 0, originalHeight > 0 else { return [] }
        let width = CGFloat(imageWidth), height = CGFloat(imageHeight)
        let ratio = min(width / originalWidth, height / originalHeight)
        let renderedWidth = originalWidth * ratio
        let renderedHeight = originalHeight * ratio
        let padX = (width - renderedWidth) / 2
        let padY = (height - renderedHeight) / 2

        var target: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let result = CVPixelBufferCreate(kCFAllocatorDefault, imageWidth, imageHeight,
                                         kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                         &target)
        guard result == kCVReturnSuccess, let target else {
            throw NSError(domain: "VelmiraYOLO", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "تعذر تجهيز إطار YOLO."])
        }
        let transformed = CIImage(cvPixelBuffer: frame)
            .transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
            .transformed(by: CGAffineTransform(translationX: padX, y: padY))
        let background = CIImage(color: .black)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(transformed.composited(over: background), to: target)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            imageInput: MLFeatureValue(pixelBuffer: target)
        ])
        let prediction = try model.prediction(from: input)
        guard let tensor = prediction.featureValue(for: "var_910")?.multiArrayValue else {
            throw NSError(domain: "VelmiraYOLO", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "مخرجات YOLOv8 غير موجودة."])
        }
        return try Self.decode(tensor, scoreThreshold: threshold,
                               inputWidth: Double(width), inputHeight: Double(height),
                               padX: Double(padX), padY: Double(padY),
                               contentWidth: Double(renderedWidth),
                               contentHeight: Double(renderedHeight))
    }

    /// Model export: float32 [1,5,8400] where rows 0..3 are xywh
    /// *in pixels of the 640px letterboxed model input*, row 4 is Enemy score.
    /// Shape and strides are checked; NMS is not part of the trained model.
    static func decode(_ tensor: MLMultiArray, scoreThreshold: Float,
                       inputWidth: Double, inputHeight: Double,
                       padX: Double, padY: Double,
                       contentWidth: Double, contentHeight: Double) throws -> [YOLOPersonCandidate] {
        let shape = tensor.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == 5,
              shape[2] == 8400, tensor.dataType == .float32,
              inputWidth > 0, inputHeight > 0,
              contentWidth > 0, contentHeight > 0 else {
            throw NSError(domain: "VelmiraYOLO", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                            "أبعاد Tensor الخاصة بنموذج YOLOv8 لا تطابق [1,5,8400]."])
        }
        let strideChannel = tensor.strides[1].intValue
        let stridePrediction = tensor.strides[2].intValue
        let pointer = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        var proposals = [YOLOPersonCandidate]()
        proposals.reserveCapacity(128)

        for index in 0..<shape[2] {
            let confidence = pointer[4 * strideChannel + index * stridePrediction]
            guard confidence.isFinite, confidence >= scoreThreshold else { continue }
            let cx = Double(pointer[index * stridePrediction])
            let cy = Double(pointer[strideChannel + index * stridePrediction])
            let w = Double(pointer[2 * strideChannel + index * stridePrediction])
            let h = Double(pointer[3 * strideChannel + index * stridePrediction])
            guard cx.isFinite, cy.isFinite, w.isFinite, h.isFinite,
                  w > 0, h > 0 else { continue }
            let x0 = (cx - w / 2 - padX) / contentWidth
            let x1 = (cx + w / 2 - padX) / contentWidth
            // Core ML YOLO output xywh is top-left-based pixel geometry.
            let top = (cy - h / 2 - padY) / contentHeight
            let bottom = (cy + h / 2 - padY) / contentHeight
            let left = max(0, min(1, x0))
            let right = max(0, min(1, x1))
            let lower = max(0, min(1, 1 - bottom))
            let upper = max(0, min(1, 1 - top))
            guard right - left >= 0.01, upper - lower >= 0.035 else { continue }
            proposals.append(YOLOPersonCandidate(
                box: CGRect(x: left, y: lower,
                            width: right - left, height: upper - lower),
                confidence: confidence))
        }
        proposals.sort { $0.confidence > $1.confidence }
        var accepted = [YOLOPersonCandidate]()
        for proposed in proposals {
            if accepted.allSatisfy({ Self.iou($0.box, proposed.box) <= 0.45 }) {
                accepted.append(proposed)
                if accepted.count == 24 { break }
            }
        }
        return accepted
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b)
        if rect.isNull { return 0 }
        let intersect = rect.width * rect.height
        let union = a.width * a.height + b.width * b.height - intersect
        return union > 0 ? intersect / union : 0
    }
}

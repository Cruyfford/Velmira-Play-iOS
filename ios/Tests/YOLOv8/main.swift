import Foundation
import CoreML

func check(_ condition: @autoclosure () -> Bool, _ explanation: String) {
    if !condition() { fatalError(explanation) }
}

let tensor = try MLMultiArray(shape: [1, 5, 8400], dataType: .float32)
// Format: [batch, xywh+1 Enemy score, candidate]; values in 640px image coordinates.
func candidate(_ i: Int, x: Float, y: Float, width: Float, height: Float, score: Float) {
    tensor[[0, 0, NSNumber(value: i)]] = NSNumber(value: x)
    tensor[[0, 1, NSNumber(value: i)]] = NSNumber(value: y)
    tensor[[0, 2, NSNumber(value: i)]] = NSNumber(value: width)
    tensor[[0, 3, NSNumber(value: i)]] = NSNumber(value: height)
    tensor[[0, 4, NSNumber(value: i)]] = NSNumber(value: score)
}
candidate(0, x: 450, y: 322, width: 100, height: 140, score: 0.91)
candidate(1, x: 452, y: 323, width: 100, height: 140, score: 0.85) // duplicate, NMS
candidate(2, x: 100, y: 160, width: 65, height: 80, score: 0.05)   // below threshold
let boxes = try CoreMLYOLODetector.decode(tensor, scoreThreshold: 0.30,
                                          inputWidth: 640, inputHeight: 640,
                                          padX: 0, padY: 140,
                                          contentWidth: 640, contentHeight: 360)
check(boxes.count == 1, "Must threshold Enemy confidence and suppress duplicate boxes")
check(boxes[0].confidence > 0.90, "Must preserve confidence")
check(abs(boxes[0].box.midX - (450.0/640.0)) < 0.001, "Unletterbox X must be correct")
check(abs(boxes[0].box.midY - 0.5) < 0.01, "Y coordinate should map correctly")
let without = try CoreMLYOLODetector.decode(tensor, scoreThreshold: 0.95,
                                            inputWidth: 640, inputHeight: 640,
                                            padX: 0, padY: 140,
                                            contentWidth: 640, contentHeight: 360)
check(without.isEmpty, "High threshold must reject all low-confidence boxes")
let invalid = try MLMultiArray(shape: [1, 80, 8400], dataType: .float32)
do {
    _ = try CoreMLYOLODetector.decode(invalid, scoreThreshold: 0.25,
                                      inputWidth: 640, inputHeight: 640,
                                      padX: 0, padY: 140,
                                      contentWidth: 640, contentHeight: 360)
    fatalError("Wrong model tensor shape should fail loudly")
} catch {
    check((error as NSError).domain == "VelmiraYOLO", "Wrong shape should be explicitly rejected")
}
print("Fine-tuned YOLOv8n Core ML tensor decode tests passed")

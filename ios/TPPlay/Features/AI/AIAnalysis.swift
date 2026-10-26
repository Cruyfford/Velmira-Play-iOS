import SwiftUI
import Vision
import CoreVideo
import ImageIO

struct HumanDetection: Identifiable, Sendable {
    let id: UUID
    let box: CGRect
    let confidence: Float
}
struct HumanAnalysis: Sendable {
    let detections: [HumanDetection]
    let imageSize: CGSize
    let capturedAt: TimeInterval
    let milliseconds: Double
    let error: String?
}

/// Analysis is independent from controller output; assistance consumes fresh results only.
@MainActor
final class AIAnalysisState: ObservableObject {
    static let shared = AIAnalysisState()
    @Published var colorMode = false { didSet { configure() } }
    @Published var colorHue = 0.0 { didSet { configure() } }
    @Published var colorTolerance = 0.045 { didSet { configure() } }
    @Published var enabled = false { didSet { configure() } }
    @Published var threshold = 0.6 { didSet { configure() } }
    @Published var rate = 3.0 { didSet { configure() } }
    @Published private(set) var result: HumanAnalysis?
    func configure() {
        AIFrameAnalyzer.shared.configure(enabled: enabled, threshold: Float(threshold), rate: rate, colorMode: colorMode,
            color: ColorTrackingConfiguration(hue: colorHue, tolerance: colorTolerance))
        result = nil
    }
    func accept(_ value: HumanAnalysis) { result = value }
    func clear() { result = nil; AIFrameAnalyzer.shared.invalidate() }
}
private final class RetainedVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

final class AIFrameAnalyzer: @unchecked Sendable {
    static let shared = AIFrameAnalyzer()
    private let queue = DispatchQueue(label: "app.velmira.vision", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var paused = false
    private var busy = false
    private var generation: UInt64 = 0
    private var threshold: Float = 0.6
    private var rate = 3.0
    private var colorMode = false
    private var color = ColorTrackingConfiguration()
    private var previousTime: TimeInterval = 0
    func configure(enabled: Bool, threshold: Float, rate: Double, colorMode: Bool, color: ColorTrackingConfiguration) {
        lock.lock(); defer { lock.unlock() }
        self.colorMode = colorMode; self.color = color
        self.enabled = enabled; self.threshold = min(0.95, max(0.2, threshold))
        self.rate = min(8, max(1, rate)); generation &+= 1
    }
    func invalidate() { lock.lock(); generation &+= 1; lock.unlock() }
    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; generation &+= 1; lock.unlock()
    }
    private func current(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && !paused && generation == token
    }
    func submit(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let thermal = ProcessInfo.processInfo.thermalState
        lock.lock()
        let effectiveRate = (thermal == .serious || thermal == .critical) ? min(rate, 2) : rate
        guard enabled && !paused && !busy && now - previousTime >= 1 / effectiveRate else { lock.unlock(); return }
        busy = true; previousTime = now
        let token = generation; let minimum = threshold
        let useColor = colorMode; let colorConfiguration = color
        lock.unlock()
        let frame = RetainedVideoFrame(pixelBuffer)
        queue.async { [self, frame] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard current(token) else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let size = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
            let report: HumanAnalysis
            do {
                let detections: [HumanDetection]
                if useColor {
                    detections = try ColorTargetDetector.detect(frame.buffer, configuration: colorConfiguration).map {
                        HumanDetection(id: UUID(), box: $0, confidence: 1)
                    }
                } else {
                    let request = VNDetectHumanRectanglesRequest()
                    request.upperBodyOnly = false
                    let handler = VNImageRequestHandler(cvPixelBuffer: frame.buffer, orientation: .up, options: [:])
                    try handler.perform([request])
                    detections = (request.results ?? []).filter { $0.confidence >= minimum }.map {
                        HumanDetection(id: UUID(), box: $0.boundingBox, confidence: $0.confidence)
                    }
                }
                report = HumanAnalysis(detections: detections, imageSize: size, capturedAt: now,
                                       milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, error: nil)
            } catch {
                report = HumanAnalysis(detections: [], imageSize: size, capturedAt: now, milliseconds: 0,
                                       error: error.localizedDescription)
            }
            guard current(token) else { return }
            Task { @MainActor in
                guard self.current(token) else { return }
                AIAnalysisState.shared.accept(report)
            }
        }
    }
}

struct AIAnalysisOverlay: View {
    @ObservedObject private var assistance = AssistanceState.shared
    @ObservedObject private var model = AIAnalysisState.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            GeometryReader { geometry in
                if model.enabled, let result = model.result,
                   ProcessInfo.processInfo.systemUptime - result.capturedAt < 0.8,
                   result.imageSize.width > 0, result.imageSize.height > 0 {
                    let scale = min(geometry.size.width / result.imageSize.width, geometry.size.height / result.imageSize.height)
                    let width = result.imageSize.width * scale
                    let height = result.imageSize.height * scale
                    let left = (geometry.size.width - width) / 2
                    let top = (geometry.size.height - height) / 2
                    if assistance.armed {
                        Circle().stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
                            .frame(width: assistance.configuration.radius * 2 * width, height: assistance.configuration.radius * 2 * height)
                            .position(x: left + width / 2, y: top + height / 2)
                    }
                    if let target = assistance.target {
                        Circle().stroke(Color.yellow, lineWidth: 2).frame(width: 16, height: 16)
                            .position(x: left + target.x * width, y: top + target.y * height)
                    }
                    ForEach(result.detections) { detection in
                        let r = detection.box
                        Rectangle().stroke(Color.cyan, lineWidth: 2)
                            .frame(width: r.width * width, height: r.height * height)
                            .overlay(alignment: .topLeading) {
                                Text(model.colorMode ? "علامة لون" : "شخص محتمل \(Int(detection.confidence * 100))٪")
                                    .font(.caption2.bold()).foregroundStyle(.black)
                                    .padding(3).background(Color.cyan)
                            }
                            .position(x: left + r.midX * width, y: top + (1 - r.midY) * height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AIAnalysisSettings: View {
    @ObservedObject private var model = AIAnalysisState.shared
    var body: some View {
        NavigationStack {
            Form {
                Section("الذكاء الاصطناعي — معاينة البث") {
                    Toggle("تشغيل تحليل الصورة", isOn: $model.enabled)
                    Toggle("تتبّع لون العلامة بدل كشف الأشخاص", isOn: $model.colorMode)
                    if model.colorMode {
                        HStack {
                            Button("أحمر") { model.colorHue = 0 }
                            Button("أرجواني") { model.colorHue = 0.88 }
                            Button("أصفر") { model.colorHue = 0.16 }
                        }.buttonStyle(.bordered)
                        Rectangle().fill(Color(hue: model.colorHue, saturation: 1, brightness: 1)).frame(height: 18)
                        Slider(value: $model.colorHue, in: 0...1) { Text("لون العلامة") }
                        Slider(value: $model.colorTolerance, in: 0.01...0.15) { Text("سماحية اللون") }
                        Text("اختر لون اسم الخصم. أي عنصر بنفس اللون قد يُكشف خطأً؛ لا توجد معرفة بهوية اللاعب.")
                    }
                    Text("ابدأ اتصال PS5 من قسم اللعب. تظهر الإطارات فوق الأشخاص المحتملين داخل البث، دون إرسال الصور إلى خادم.")
                    Text("التحليل وحده للمعاينة. فعّل الحركة والماكروز بشكل منفصل من قسم التحكم.").foregroundStyle(.cyan)
                }
                Section("الأداء") {
                    Slider(value: $model.threshold, in: 0.2...0.95, step: 0.05) {
                        Text("عتبة الثقة")
                    }
                    Text("عتبة الثقة: \(Int(model.threshold * 100))٪")
                    Picker("التحليلات المطلوبة في الثانية", selection: $model.rate) {
                        Text("خفيف — 3").tag(3.0)
                        Text("متوازن — 5").tag(5.0)
                        Text("أعلى — 8").tag(8.0)
                    }
                    Text("لا تعني هذه القيم معدل إطارات اللعبة. يُخفَّض التحليل تلقائيًا عند ارتفاع حرارة الجهاز.")
                }
                Section("حالة التحليل") {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        if let result = model.result {
                            if let error = result.error { Text(error).foregroundStyle(.red) }
                            else {
                                Text("الأشخاص المحتملون: \(result.detections.count)")
                                Text("زمن التحليل: \(Int(result.milliseconds)) ms")
                                if ProcessInfo.processInfo.systemUptime - result.capturedAt >= 0.8 {
                                    Text("لا توجد نتيجة حديثة؛ الإطارات القديمة مخفية.")
                                }
                            }
                        } else { Text(model.enabled ? "بانتظار إطارات من بث PS5" : "التحليل متوقف") }
                    }
                }
                Section("حدود الكشف") {
                    Text("Apple Vision نموذج عام، غير مدرَّب هنا على Call of Duty. قد يفوّت الشخصيات أو يكتشف مناطق خاطئة، ولا يميز الخصم من الصديق أو يؤكد موت الشخصية. درجة الثقة ليست ضمانًا.")
                    Text("نسخة تطوير: الأداء والاتصال بحاجة لتجربة على iPhone 17 Pro وPS5.")
                }
            }
            .navigationTitle("ذكاء Velmira")
        }
    }
}

import SwiftUI
import CoreVideo
import ImageIO
import PhotosUI
import CoreImage
import Vision
import ImageIO

/// Bounded, on-device diagnostics. Never logs gamertags, screenshots or PSN credentials.
@MainActor
final class VelmiraLiveDiagnostics: ObservableObject {
    static let shared = VelmiraLiveDiagnostics()
    @Published private(set) var lines: [String] = []
    @Published private(set) var measuredYOLOms = 0.0
    @Published private(set) var analysisRate = 0.0
    @Published private(set) var droppedBusy = 0
    @Published private(set) var thermalDescription = "عادي"
    @Published private(set) var lastOCRStatus = "بانتظار قراءة الأسماء"
    private let formatter = ISO8601DateFormatter()
    private var lastLoggedErrorAt: TimeInterval = 0
    func record(_ kind: String, _ detail: String) {
        lines.append("\(formatter.string(from: Date())) | \(kind) | \(String(detail.prefix(160)).replacingOccurrences(of: "\n", with: " "))")
        if lines.count > 180 { lines.removeFirst(lines.count - 180) }
    }
    func updateInference(milliseconds: Double, limit: Double, dropped: Int,
                         temperature: ProcessInfo.ThermalState, error: String?) {
        if milliseconds.isFinite && milliseconds > 0 { measuredYOLOms = milliseconds }
        analysisRate = limit
        droppedBusy = dropped
        switch temperature {
        case .nominal: thermalDescription = "عادي"
        case .fair: thermalDescription = "دافئ"
        case .serious: thermalDescription = "مرتفع — خفض الأداء"
        case .critical: thermalDescription = "حرج — تقليل التحليل"
        @unknown default: thermalDescription = "غير معروف"
        }
        if error != nil, ProcessInfo.processInfo.systemUptime - lastLoggedErrorAt > 3 {
            record("YOLO", "تعذر تنفيذ التحليل، افحص سجل النظام")
            lastLoggedErrorAt = ProcessInfo.processInfo.systemUptime
        }
    }
    func updateOCR(_ status: String) { lastOCRStatus = status }
    func clear() { lines = []; record("LOG", "تم مسح سجل التشخيص") }
    var exportText: String {
        (["Velmira Play local diagnostics",
          "Generated: \(formatter.string(from: Date()))",
          "No gamer tags, video frames, PSN credentials or connection addresses stored.",
          "Thermal: \(thermalDescription); inference ms: \(measuredYOLOms); analysis cap: \(analysisRate); dropped busy: \(droppedBusy)",
          ""] + lines).joined(separator: "\n")
    }
}

/// Analysis is independent from controller output; assistance consumes fresh results only.
@MainActor
final class AIAnalysisState: ObservableObject {
    static let shared = AIAnalysisState()
    @Published var colorMode = true { didSet { configure() } }
    @Published var hybridMode = true { didSet { configure() } }
    @Published var adaptiveBodyMarker = true { didSet { configure() } }
    @Published var showPlayerBoxes = true
    /// Defaults ON: only a confirmed opposing name above a YOLO body can authorize tracking.
    @Published var protectTeammates = true
    @Published var precisionMode = true { didSet { configure() } }
    private var persistence = StableDetectionFilter()
    @Published var colorHue = 0.0 { didSet { configure() } }
    @Published var colorTolerance = 0.045 { didSet { configure() } }
    @Published var enabled = false { didSet { configure() } }
    @Published var threshold = 0.30 { didSet { configure() } }
    @Published var rate = 12.0 { didSet { configure() } }
    @Published private(set) var result: HumanAnalysis?
    @Published private(set) var liveNameMatches: [LiveNameMatch] = []
    private var pendingNameMatches: [String: (sample: LiveNameMatch, hits: Int)] = [:]
    private struct SavedAISettings: Codable {
        var colorMode: Bool
        var hybridMode: Bool
        var precisionMode: Bool
        var colorHue: Double
        var colorTolerance: Double
        var enabled: Bool
        var threshold: Double
        var rate: Double
    }
    private let settingsKey = "velmira.ai.explicitSave.v1"
    private let adaptiveMarkerKey = "velmira.ai.bodyMarker.v1"
    private let playerBoxesKey = "velmira.ai.greenPlayerBoxes.v1"
    private let teammateProtectionKey = "velmira.ai.requireConfirmedOpponent.v1"

    private init() {
        restoreSavedSettings()
    }

    @discardableResult
    func saveSettings() -> Bool {
        let value = SavedAISettings(colorMode: colorMode, hybridMode: hybridMode,
                                    precisionMode: precisionMode, colorHue: colorHue,
                                    colorTolerance: colorTolerance, enabled: enabled,
                                    threshold: threshold, rate: rate)
        guard let data = try? JSONEncoder().encode(value) else { return false }
        UserDefaults.standard.set(data, forKey: settingsKey)
        UserDefaults.standard.set(adaptiveBodyMarker, forKey: adaptiveMarkerKey)
        UserDefaults.standard.set(showPlayerBoxes, forKey: playerBoxesKey)
        UserDefaults.standard.set(protectTeammates, forKey: teammateProtectionKey)
        return true
    }

    func restoreSavedSettings() {
        adaptiveBodyMarker = UserDefaults.standard.object(forKey: adaptiveMarkerKey) as? Bool ?? true
        showPlayerBoxes = UserDefaults.standard.object(forKey: playerBoxesKey) as? Bool ?? true
        protectTeammates = UserDefaults.standard.object(forKey: teammateProtectionKey) as? Bool ?? true
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let value = try? JSONDecoder().decode(SavedAISettings.self, from: data) else {
            return
        }
        colorMode = value.colorMode
        hybridMode = value.hybridMode
        precisionMode = value.precisionMode
        colorHue = value.colorHue
        colorTolerance = value.colorTolerance
        enabled = value.enabled
        threshold = value.threshold
        rate = value.rate
    }

    func configure() {
        AIFrameAnalyzer.shared.configure(enabled: enabled, threshold: Float(threshold), rate: rate,
            colorMode: colorMode, hybridMode: hybridMode,
            adaptiveBodyMarker: adaptiveBodyMarker,
            color: ColorTrackingConfiguration(hue: colorHue, tolerance: colorTolerance))
        result = nil
        liveNameMatches = []
        pendingNameMatches.removeAll()
        persistence.reset()
    }
    /// Configure image analysis only; activation of controller assistance stays manual.
    func prepareHybridTracking() {
        colorMode = true
        hybridMode = true
        precisionMode = true
        adaptiveBodyMarker = true
        threshold = 0.30
        rate = 12
        enabled = true
    }

    func accept(_ value: HumanAnalysis) {
        let hybrid = true
        guard precisionMode || hybrid else { result = value; return }
        if value.error != nil {
            persistence.reset()
            liveNameMatches = []
            pendingNameMatches.removeAll()
            result = value
            return
        }
        // Confirm the body, not small moving letter fragments. Hybrid mode
        // always needs two independent observations, even without precision mode.
        let evidence = hybrid ? value.detections.filter { $0.matchedPersonBox != nil } : value.detections
        let boxes = evidence.map { hybrid ? ($0.matchedPersonBox ?? $0.box) : $0.box }
        let confirmations = persistence.update(boxes, at: value.capturedAt,
                                               requiredFrames: hybrid ? 2 : 3)
        let confirmed = confirmations.map { match -> HumanDetection in
            let item = evidence[match.index]
            return HumanDetection(id: match.id, box: item.box, confidence: item.confidence,
                                  humanSupported: item.humanSupported,
                                  matchedPersonBox: item.matchedPersonBox)
        }
        result = HumanAnalysis(detections: confirmed, imageSize: value.imageSize,
                               capturedAt: value.capturedAt,
                               milliseconds: value.milliseconds, error: value.error,
                               visiblePlayerBoxes: value.visiblePlayerBoxes)
    }
    func acceptNameMatches(_ names: [LiveNameMatch], sampledAt: TimeInterval) {
        guard enabled, let result, result.error == nil,
              result.capturedAt >= sampledAt - 0.10,
              result.capturedAt - sampledAt <= 0.90 else { return }
        // Only show names after two consistent scans of the same player body.
        pendingNameMatches = pendingNameMatches.filter {
            sampledAt - $0.value.sample.capturedAt <= 2.2
        }
        var verified: [LiveNameMatch] = []
        for candidate in names {
            let key = candidate.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if let prior = pendingNameMatches[key],
               prior.sample.side == candidate.side,
               sampledAt > prior.sample.capturedAt,
               sampledAt - prior.sample.capturedAt <= 2.2,
               NameplateRosterAssociation.matchingBox(prior.sample.body, candidate.body) {
                let hits = min(5, prior.hits + 1)
                pendingNameMatches[key] = (sample: candidate, hits: hits)
                if hits >= 2 { verified.append(candidate) }
            } else {
                pendingNameMatches[key] = (sample: candidate, hits: 1)
            }
        }
        liveNameMatches = verified
        VelmiraLiveDiagnostics.shared.updateOCR("تم تأكيد \(verified.count) من تسميات اللاعبين")
    }
    func invalidateRosterMatches() {
        liveNameMatches = []
        pendingNameMatches.removeAll()
    }
    func clear() {
        result = nil
        liveNameMatches = []
        pendingNameMatches.removeAll()
        persistence.reset()
        AIFrameAnalyzer.shared.invalidate()
    }
}
private final class RetainedVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Separate, throttled text recognition for *floating gamer tags*. Never
/// alters controller input. YOLO remains the sole body detection system.
private final class OnScreenNameplateOCR: @unchecked Sendable {
    static let shared = OnScreenNameplateOCR()
    private let queue = DispatchQueue(label: "app.velmira.nameplate.ocr", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastScan: TimeInterval = 0

    func submit(_ source: CVPixelBuffer,
                bodies: [CGRect], roster: [KnownRosterPlayer],
                capturedAt: TimeInterval) {
        guard !bodies.isEmpty, !roster.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let heat = ProcessInfo.processInfo.thermalState
        let spacing = heat == .serious ? 2.0 : (heat == .fair ? 1.15 : 0.85)
        guard !busy, now - lastScan >= spacing, heat != .critical else {
            lock.unlock()
            return
        }
        busy = true
        lastScan = now
        lock.unlock()
        let frame = RetainedVideoFrame(source)
        queue.async { [self, frame, bodies, roster] in
            defer { lock.lock(); busy = false; lock.unlock() }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.004
            do {
                try VNImageRequestHandler(cvPixelBuffer: frame.buffer, options: [:]).perform([request])
                let items: [NameplateTextObservation] = (request.results ?? []).compactMap {
                    observation in
                    guard let text = observation.topCandidates(1).first,
                          text.confidence >= 0.56 else { return nil }
                    return NameplateTextObservation(text: text.string,
                                                    box: observation.boundingBox,
                                                    confidence: text.confidence)
                }
                // Never attach a scoreboard row to a body visible through the
                // transparent leaderboard panel.
                let hasScoreboard = items.contains {
                    let label = $0.text.uppercased()
                    return label.contains("SCOREBOARD")
                }
                let matches = hasScoreboard ? [] :
                    NameplateRosterAssociation.match(
                        texts: items, bodies: bodies,
                        players: roster, capturedAt: capturedAt)
                Task { @MainActor in
                    AIAnalysisState.shared.acceptNameMatches(matches, sampledAt: capturedAt)
                }
            } catch {
                Task { @MainActor in
                    AIAnalysisState.shared.acceptNameMatches([], sampledAt: capturedAt)
                }
            }
        }
    }
}

final class AIFrameAnalyzer: @unchecked Sendable {
    static let shared = AIFrameAnalyzer()
    private let queue = DispatchQueue(label: "app.velmira.yolov8", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var paused = false
    private var busy = false
    private var generation: UInt64 = 0
    private var threshold: Float = 0.30
    private var rate = 3.0
    private var colorMode = false
    private var hybridMode = true
    private var adaptiveBodyMarker = true
    private var color = ColorTrackingConfiguration()
    private var previousTime: TimeInterval = 0
    private var averagedMS = 0.0
    private var droppedBusyCount = 0
    private var lastTelemetryTime: TimeInterval = 0
    private var lastThermal: ProcessInfo.ThermalState = .nominal
    func configure(enabled: Bool, threshold: Float, rate: Double, colorMode: Bool,
                   hybridMode: Bool, adaptiveBodyMarker: Bool,
                   color: ColorTrackingConfiguration) {
        lock.lock(); defer { lock.unlock() }
        self.colorMode = colorMode
        self.hybridMode = hybridMode
        self.adaptiveBodyMarker = adaptiveBodyMarker
        self.color = color
        self.enabled = enabled; self.threshold = min(0.95, max(0.15, threshold))
        self.rate = min(24, max(1, rate)); generation &+= 1
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
        let effectiveRate = AdaptiveAnalysisBudget.limit(
            requested: rate, averageInferenceMS: averagedMS,
            thermalLevel: AdaptiveAnalysisBudget.level(thermal))
        guard enabled && !paused else { lock.unlock(); return }
        if busy { droppedBusyCount += 1; lock.unlock(); return }
        guard now - previousTime >= 1 / effectiveRate else { lock.unlock(); return }
        busy = true; previousTime = now
        let token = generation; let minimum = threshold
        lock.unlock()
        let frame = RetainedVideoFrame(pixelBuffer)
        queue.async { [self, frame] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard current(token) else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let size = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
            let report: HumanAnalysis
            do {
                // This fine-tuned YOLOv8n predicts the one labeled Enemy
                // class directly; it no longer requires a colored nameplate,
                // OCR, manual names, or Apple Vision to permit detection.
                // Enemy labels are probabilistic and may be wrong in MWIII.
                let found = try CoreMLYOLODetector.shared.detect(frame.buffer, threshold: minimum)
                let people = found.map(\.box)
                let detections = found.map { candidate in
                    HumanDetection(id: UUID(), box: candidate.box,
                                   confidence: candidate.confidence,
                                   humanSupported: true,
                                   matchedPersonBox: candidate.box)
                }
                report = HumanAnalysis(detections: detections, imageSize: size, capturedAt: now,
                                       milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                       error: nil, visiblePlayerBoxes: people)
            } catch {
                report = HumanAnalysis(detections: [], imageSize: size, capturedAt: now, milliseconds: 0,
                                       error: error.localizedDescription)
            }
            guard current(token) else { return }
            let finishedAt = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if report.milliseconds > 0 {
                averagedMS = averagedMS == 0 ? report.milliseconds : averagedMS * 0.82 + report.milliseconds * 0.18
            }
            let shouldReport = finishedAt - lastTelemetryTime > 0.9 || thermal != lastThermal
            if shouldReport { lastTelemetryTime = finishedAt; lastThermal = thermal }
            let dropCount = droppedBusyCount
            lock.unlock()
            Task { @MainActor in
                guard self.current(token) else { return }
                if shouldReport {
                    VelmiraLiveDiagnostics.shared.updateInference(
                        milliseconds: report.milliseconds, limit: effectiveRate,
                        dropped: dropCount, temperature: thermal, error: report.error)
                }
                AIAnalysisState.shared.accept(report)
                if report.error == nil && !report.visiblePlayerBoxes.isEmpty {
                    let roster = MatchRoster.shared.names
                        .filter { $0.side != .unknown }
                        .map { KnownRosterPlayer(name: $0.name, side: $0.side) }
                    if !roster.isEmpty {
                        OnScreenNameplateOCR.shared.submit(
                            frame.buffer, bodies: report.visiblePlayerBoxes,
                            roster: roster, capturedAt: report.capturedAt)
                    }
                }
            }
        }
    }
}

struct AIAnalysisOverlay: View {
    @ObservedObject private var assistance = AssistanceState.shared
    @ObservedObject private var model = AIAnalysisState.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            GeometryReader { geometry in
                if model.enabled, let result = model.result,
                   ProcessInfo.processInfo.systemUptime - result.capturedAt < 0.8,
                   result.imageSize.width > 0, result.imageSize.height > 0 {
                    let scale = min(geometry.size.width / result.imageSize.width, geometry.size.height / result.imageSize.height)
                    let width = result.imageSize.width * scale
                    let height = result.imageSize.height * scale
                    let left = (geometry.size.width - width) / 2
                    let top = (geometry.size.height - height) / 2
                    // Keep the stream uncluttered: a small dot instead of
                    // the old large targeting-radius rings.
                    if let target = assistance.target {
                        Circle().fill(.yellow).frame(width: 7, height: 7)
                            .overlay { Circle().stroke(.black, lineWidth: 1) }
                            .position(x: left + target.x * width, y: top + target.y * height)
                    }
                    if model.showPlayerBoxes {
                        ForEach(result.visiblePlayerBoxes.indices, id: \.self) { index in
                            let body = result.visiblePlayerBoxes[index]
                            let matches = model.liveNameMatches.filter {
                                ProcessInfo.processInfo.systemUptime - $0.capturedAt <= 1.55 &&
                                NameplateRosterAssociation.matchingBox(body, $0.body)
                            }
                            let named = matches.count == 1 ? matches.first : nil
                            let boxColor: Color = named?.side == .friendly
                                ? .cyan : (named?.side == .opponent ? .orange : .green)
                            Rectangle().stroke(boxColor, lineWidth: 2.5)
                                .frame(width: body.width * width, height: body.height * height)
                                .overlay(alignment: .topLeading) {
                                    Text(named.map { "\($0.name) • \($0.side == .friendly ? "محمي: من فريقي" : "خصم مؤكد")" } ??
                                         (model.protectTeammates ? "مجهول — التتبع محظور" : PlayerVisualCues.proximity(for: body)))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.78), in: Capsule())
                                        .offset(y: -23)
                                        .fixedSize()
                                }
                                .position(x: left + body.midX * width,
                                          y: top + (1 - body.midY) * height)
                        }
                    }
                    ForEach(result.detections) { detection in
                        if model.adaptiveBodyMarker, let body = detection.matchedPersonBox,
                           TeamTargetSafety.trackingSample(
                               from: result, names: model.liveNameMatches,
                               roster: MatchRoster.shared.names.map { KnownRosterPlayer(name: $0.name, side: $0.side) },
                               now: ProcessInfo.processInfo.systemUptime,
                               requireConfirmedOpponent: model.protectTeammates
                           ).boxes.contains(where: { NameplateRosterAssociation.matchingBox($0, body) }) {
                            let position = VisualBodyAssociation.selectedPoint(
                                in: body, x: assistance.configuration.pointX,
                                y: assistance.configuration.pointY)
                            Circle().fill(Color.green)
                                .frame(width: 8, height: 8)
                                .overlay { Circle().stroke(Color.black, lineWidth: 1.5) }
                                .position(x: left + position.x * width,
                                          y: top + position.y * height)
                        }
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
    @State private var savedNotice = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                NavigationLink { MatchRosterView() } label: {
                    Label("قائمة فريقي والخصوم", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(AcidButtonStyle(active: true))
                VelmiraSection("الذكاء الاصطناعي — معاينة البث") {
                    Toggle("حماية فريقي — تتبع الخصوم المؤكدين فقط", isOn: $model.protectTeammates)
                    Text("مفعّلة افتراضياً: يمنع توجيه التصويب نحو الحليف أو أي لاعب مجهول. يتوقف التتبع حين لا يمكن قراءة اسم الخصم فوق جسمه بوضوح. يمكن تعطيلها يدوياً، لكن ذلك يعيد احتمال استهداف الحلفاء.")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("كشف MW3 تلقائي — YOLOv8n المدرّب") { model.prepareHybridTracking() }
                    Toggle("تشغيل تحليل الصورة", isOn: $model.enabled)
                    Text("YOLOv8n المدرّب على بيانات MW3 يكشف فئة Enemy من صورة اللاعب دون إدخال الاسم أو لون HUD.")
                    Toggle("إظهار مربعات اللاعبين وتصنيف فريقهم", isOn: $model.showPlayerBoxes)
                    Text("سماوي: لاعب فريقي محمي. برتقالي: خصم قرئ اسمه وتأكد عبر عدة إطارات. أخضر: غير مصنف، لا يُتتبّع في وضع حماية الفريق. القرب نسبي وليس بالمتر.")
                        .font(.footnote)
                    Toggle("إظهار موضع الجسم المختار مع تغير مسافة اللاعب", isOn: $model.adaptiveBodyMarker)
                    Text("يتتبع الموضع داخل الجسم مع قفل الهدف المستمر عند تفعيله، مع L2 وبدونه. إظهار العلامة خيار مرئي فقط.")
                        .font(.footnote)
                    Toggle("تقليل الأخطاء — تأكيد عبر الإطارات", isOn: $model.precisionMode)
                    if model.precisionMode {
                        Text("يتطلب تأكيد هدف YOLO في صورتين متتابعتين قبل السماح بالقفل. لا يحرّك التصويب نحو هدف غائب.")
                            .font(.footnote).foregroundStyle(.orange)
                        Text("فئة Enemy في النموذج تقريبية، وقد تخطئ في تمييز الحليف من الخصم.")
                            .font(.footnote)
                    }
                    Text("ابدأ اتصال PS5 من قسم اللعب. تظهر الإطارات فوق الأشخاص المحتملين داخل البث، دون إرسال الصور إلى خادم.")
                    Text("التحليل وحده للمعاينة. فعّل الحركة والماكروز بشكل منفصل من قسم التحكم.").foregroundStyle(.cyan)
                }
                VelmiraSection("الأداء") {
                    Slider(value: $model.threshold, in: 0.2...0.95, step: 0.05) {
                        Text("عتبة الثقة")
                    }
                    Text("عتبة الثقة: \(Int(model.threshold * 100))٪")
                    Picker("معدل التحليل", selection: $model.rate) {
                        Text("3").tag(3.0)
                        Text("5").tag(5.0)
                        Text("8").tag(8.0)
                        Text("12").tag(12.0)
                        Text("20 سريع").tag(20.0)
                        Text("24 أقصى").tag(24.0)
                    }.pickerStyle(.segmented)
                    Text("هذه طلبات لتحليل YOLO وليست FPS مضموناً. تُسقط الإطارات إذا كان التحليل مشغولاً، ويُخفَّض المعدّل عند حرارة الجهاز.")
                }
                VelmiraSection("حفظ إعدادات الذكاء الاصطناعي") {
                    Button {
                        if model.saveSettings() && AssistanceState.shared.saveSettings() {
                            savedNotice = "تم حفظ إعدادات الذكاء الاصطناعي واللون حتى بعد إغلاق التطبيق."
                        } else {
                            savedNotice = "تعذر حفظ الإعدادات."
                        }
                    } label: {
                        Label("حفظ الإعدادات", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))
                    Text(savedNotice.isEmpty
                         ? "التغييرات مؤقتة ما لم تضغط زر حفظ الإعدادات."
                         : savedNotice)
                        .font(.footnote)
                    Button("استعادة آخر إعدادات محفوظة") {
                        model.restoreSavedSettings()
                        savedNotice = "تم استعادة الإعدادات المحفوظة."
                    }
                }
                VelmiraSection("حالة التحليل") {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        if let result = model.result {
                            if let error = result.error { Text(error).foregroundStyle(.red) }
                            else {
                                Text("أجسام الأشخاص المكتشفة: \(result.visiblePlayerBoxes.count)")
                                Text("أهداف التتبّع المؤهلة: \(result.detections.count)")
                                Text("زمن التحليل: \(Int(result.milliseconds)) ms")
                                if ProcessInfo.processInfo.systemUptime - result.capturedAt >= 0.8 {
                                    Text("لا توجد نتيجة حديثة؛ الإطارات القديمة مخفية.")
                                }
                            }
                        } else { Text(model.enabled ? "بانتظار إطارات من بث PS5" : "التحليل متوقف") }
                    }
                }
                VelmiraSection("حدود الكشف") {
                    Text("نموذج YOLOv8n بدقة 640 مدرّب على 214 صورة من بيانات MW3 المتاحة. نتائج الاختبار محدودة، وقد يفوّت خصوماً أو يخلط بين الحلفاء والأعداء.")
                    Text("دقة 99٪ هدف للاختبار ببيانات حقيقية، وليست نتيجة مثبتة. لتقييم الدقة نحتاج قياس الاكتشافات الصحيحة والمفقودة والخاطئة.")
                    Text("نسخة تطوير: الأداء والاتصال بحاجة لتجربة على iPhone 17 Pro وPS5.")
                }
            }
                .padding(20)
            }
            .background(TPPlayTheme.canvas)
            .navigationTitle("الذكاء الاصطناعي")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { model.restoreSavedSettings() }
            .toolbarBackground(TPPlayTheme.canvas, for: .navigationBar)
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

struct RosterName: Identifiable, Codable {
    var id = UUID()
    var name: String
    var side: RosterSide = .unknown
    /// Saved visual identifier; it does not verify which team the player belongs to.
    var nameColorHEX: String? = nil
    /// User-confirmed team assignment always takes precedence over OCR heuristics.
    /// Optional for backwards-compatible decoding of saved rosters.
    var isConfirmedByUser: Bool? = nil
}

struct AutoRosterCandidate: Sendable {
    let name: String
    let side: RosterSide
    let hex: String
}

@MainActor
final class MatchRoster: ObservableObject {
    static let shared = MatchRoster()
    @Published var names: [RosterName] = [] {
        didSet {
            saveRoster()
            AIAnalysisState.shared.invalidateRosterMatches()
        }
    }
    @Published var reading = false
    @Published var message = "افتح لوحة النتائج داخل PS5، ثم اضغط زر قراءة الفريقين في شريط البث."
    @Published var matchNumber = 1
    @Published var autoScanEnabled = UserDefaults.standard.object(forKey: "velmira.roster.autoscan.v1") as? Bool ?? true {
        didSet {
            // Manual scoreboard OCR remains separate from YOLO body inference.
            if !autoScanEnabled { pending.removeAll() }
        }
    }

    func saveAutoScanSetting() {
        UserDefaults.standard.set(autoScanEnabled, forKey: "velmira.roster.autoscan.v1")
    }

    func restoreAutoScanSetting() {
        autoScanEnabled = UserDefaults.standard.object(forKey: "velmira.roster.autoscan.v1") as? Bool ?? true
    }
    @Published private(set) var autoStatus = "بانتظار قراءة لوحة النتائج من صورة البث."
    private struct Pending {
        var side: RosterSide
        var hex: String
        var hits: Int
        var firstTime: TimeInterval
        var lastTime: TimeInterval
    }
    private var pending: [String: Pending] = [:]
    private var generation = UUID()
    private let storageKey = "velmira.match.roster.v1"

    init() {
        if let saved = UserDefaults.standard.data(forKey: storageKey),
           let restored = try? JSONDecoder().decode([RosterName].self, from: saved) {
            names = restored
        }
    }

    private func saveRoster() {
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// OCR color is a heuristic, not proof of a team. Repeated observations
    /// are needed and manual roster corrections always win.
    func acceptAutoCandidates(_ candidates: [AutoRosterCandidate], sampledAt now: TimeInterval) {
        guard autoScanEnabled else { return }
        pending = pending.filter { now - $0.value.lastTime <= 7 }
        var processed = Set<String>()
        for candidate in candidates.prefix(10) {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2, name.count <= 24,
                  name.rangeOfCharacter(from: .letters) != nil else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard processed.insert(key).inserted else { continue }
            var entry = pending[key]
            if let current = entry, current.side == candidate.side,
               now - current.lastTime >= 0.35, now - current.lastTime <= 7 {
                entry = Pending(side: candidate.side, hex: candidate.hex,
                                hits: min(5, current.hits + 1),
                                firstTime: current.firstTime, lastTime: now)
            } else if entry == nil || entry?.side != candidate.side {
                entry = Pending(side: candidate.side, hex: candidate.hex,
                                hits: 1, firstTime: now, lastTime: now)
            }
            guard let confirmed = entry else { continue }
            pending[key] = confirmed
            guard confirmed.hits >= 2 else { continue }

            if let index = names.firstIndex(where: {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
            }) {
                guard names[index].isConfirmedByUser != true else { continue }
                if names[index].side != confirmed.side || names[index].nameColorHEX != confirmed.hex {
                    names[index].side = confirmed.side
                    names[index].nameColorHEX = confirmed.hex
                }
            } else if names.count < 64 {
                names.append(RosterName(name: name, side: confirmed.side,
                                        nameColorHEX: confirmed.hex, isConfirmedByUser: false))
            }
            autoStatus = "رُصد \(name) بلون \(candidate.side == .opponent ? "أحمر" : "أزرق") — تصنيف تلقائي قابل للتصحيح."
            // Automatic OCR only updates the roster. It must not overwrite
            // a user's saved marker hue or enable tracking without Save.
        }
    }

    /// Manual selection explicitly overrides future automatic guesses.
    func saveSelectedOpponent(name: String, colorHEX: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean.count <= 64,
              clean.rangeOfCharacter(from: .letters) != nil else {
            message = "اسم اللاعب غير صالح؛ صحح الاسم وأعد الحفظ."
            return
        }
        let normalizedColor = colorHEX.uppercased()
        guard normalizedColor.count == 7, normalizedColor.hasPrefix("#"),
              UInt32(normalizedColor.dropFirst(), radix: 16) != nil else {
            message = "لون الاسم غير صالح؛ استخدم #RRGGBB."
            return
        }
        if let index = names.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
            names[index].side = .opponent
            names[index].nameColorHEX = normalizedColor
            names[index].isConfirmedByUser = true
        } else {
            names.append(RosterName(name: clean, side: .opponent, nameColorHEX: normalizedColor,
                                    isConfirmedByUser: true))
        }
        message = "حُفظ \(clean) في الخصوم مع لون الاسم \(normalizedColor). راجع الانتماء للفريق يدويًا."
    }
    func reset() {
        generation = UUID()
        pending.removeAll()
        names = []; reading = false; matchNumber += 1
        autoStatus = "بدأت مباراة جديدة. سيُعاد اكتشاف أسماء الفريقين."
        message = "تم مسح بيانات المباراة السابقة."
    }
    /// Manual capture only: users open the MW3 scoreboard and press the button.
    /// OCR runs off the main/UI thread and never changes YOLO inference or controller output.
    func read(_ data: Data) async {
        guard let image = UIImage(data: data)?.cgImage else {
            message = "الصورة غير صالحة."
            return
        }
        await read(image)
    }

    func read(_ image: CGImage) async {
        guard !reading else { return }
        reading = true
        message = "جارٍ قراءة أسماء اللاعبين من لوحة النتائج..."
        defer { reading = false }
        let captured = ScoreboardCapturedImage(image: image)
        do {
            let items = try await Task.detached(priority: .userInitiated) {
                try MW3ScoreboardOCR.read(captured.image)
            }.value
            guard !items.isEmpty else {
                message = "لم أتعرف على لوحة نتائج MW3. افتح لوحة النتائج كاملة وجرّب مرة أخرى."
                VelmiraLiveDiagnostics.shared.record("OCR", "فشل قراءة لوحة النتائج")
                return
            }
            // Keep previous user-confirmed edits. The rest are refreshed from
            // the requested screenshot; no background or speculative additions.
            var updated = names.filter { $0.isConfirmedByUser == true }
            let confirmed = Set(updated.map {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            })
            var seen = confirmed
            for item in items {
                let normalized = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard seen.insert(normalized).inserted, updated.count < 64 else { continue }
                updated.append(RosterName(name: item.name, side: item.side,
                                          nameColorHEX: nil,
                                          isConfirmedByUser: false))
            }
            names = updated
            let friendly = items.filter { $0.side == .friendly }.count
            let opponent = items.filter { $0.side == .opponent }.count
            let unknown = items.filter { $0.side == .unknown }.count
            autoStatus = "آخر قراءة: فريقي \(friendly) • الخصوم \(opponent) • غير مصنف \(unknown)"
            message = "تم استخراج \(items.count) اسماً. تتم مطابقتها أثناء اللعب عند ظهور الاسم فوق الجسم."
            VelmiraLiveDiagnostics.shared.record("OCR", "لوحة النتائج: \(friendly) فريقي / \(opponent) خصوم / \(unknown) غير مصنف")
        } catch {
            message = "تعذرت قراءة لوحة النتائج: \(error.localizedDescription)"
        }
    }

    func swapDetectedSides() {
        for index in names.indices where names[index].side != .unknown {
            names[index].side = names[index].side == .friendly ? .opponent : .friendly
            names[index].isConfirmedByUser = true
        }
        message = "تم تبديل الفريقين وتثبيت التصنيف يدوياً."
    }
}

// The CGImage is immutable; it is safe to transfer a captured image to a
// dedicated OCR task without touching a live CVPixelBuffer on another queue.
private struct ScoreboardCapturedImage: @unchecked Sendable {
    let image: CGImage
}

/// On-demand OCR of the *visible scoreboard only*. This deliberately never
/// guesses in-game body identity from scoreboard row order.
private enum MW3ScoreboardOCR {
    private struct Line {
        let text: String
        let rect: CGRect
        let confidence: Float
    }

    private static let blocked: Set<String> = [
        "SCORE", "SCOREBOARD", "KILLS", "DEATHS", "ASSISTS",
        "PING", "LATENCY", "TIME", "TEAM", "PLAYERS", "OBJECTIVES",
        "MATCH", "STATS", "RANK", "NAME", "PLAYER", "LEVEL",
        "WIN", "LOSS", "WINS", "LOSSES", "MUTE", "REPORT",
        "SETTINGS", "COD", "MW3", "MWIII", "XP", "SPECTATING",
        "MUTED", "DISPLAY", "FRIENDS", "SOCIAL", "TAC-MAP",
        "BACK", "EXIT", "OPTIONS", "CONTINUE", "YOU",
        "SPECTATOR", "K/D", "K/D/A", "KD", "KDA", "MS"
    ]

    static func read(_ image: CGImage) throws -> [AutoRosterCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // Do not auto-correct gamer tags.
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.010
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines: [Line] = (request.results ?? []).compactMap { line in
            guard let top = line.topCandidates(1).first, top.confidence >= 0.24 else { return nil }
            let name = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return Line(text: name, rect: line.boundingBox, confidence: top.confidence)
        }
        let cues = lines.filter { line in
            let t = line.text.uppercased()
            return t.contains("SCORE") || t.contains("KILLS") ||
                   t.contains("DEATHS") || t.contains("LATENCY") ||
                   t.contains("PING") || t.contains("SCOREBOARD")
        }
        // Refuse to pollute the roster when this is ordinary gameplay HUD.
        guard cues.count >= 2 || cues.contains(where: { $0.text.uppercased().contains("SCOREBOARD") }) else {
            return []
        }
        let headerLines = lines.filter { line in
            let t = line.text.uppercased()
            return t.contains("TASK FORCE") || t.contains("SPETSNAZ") ||
                   t.contains("SPECGRU") || t.contains("RANGERS") ||
                   t.contains("KORTAC") || t.contains("KOR TAC") ||
                   t.contains("NAVY SEALS") || t.contains("MILITIA") ||
                   t.contains("OPFOR") || t.contains("[6/6]") ||
                   t.contains("(6/6)")
        }
        var rows = lines.filter { line in
            let name = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let uppercase = name.uppercased()
            guard !headerLines.contains(where: { $0.text == line.text && $0.rect == line.rect }),
                  !uppercase.contains("TASK FORCE"), !uppercase.contains("SPETSNAZ"),
                  !uppercase.contains("SPECGRU"), !uppercase.contains("SCOREBOARD"),
                  !uppercase.contains("RANGERS"), !uppercase.contains("KORTAC") else { return false }
            let words = uppercase.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let allowedPunctuation = CharacterSet(charactersIn: "_-#[]. ")
            let filteredText = name.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ||
                allowedPunctuation.contains($0)
            }
            guard filteredText.count >= name.unicodeScalars.count - 2,
                  name.count >= 3, name.count <= 30,
                  name.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2,
                  !(words.count == 1 && blocked.contains(uppercase)),
                  !words.contains(where: { blocked.contains(String($0)) && words.count <= 2 }),
                  line.rect.minX >= 0.055, line.rect.minX <= 0.50,
                  line.rect.midY >= 0.12, line.rect.midY <= 0.88,
                  line.rect.width <= 0.42, line.rect.height <= 0.064 else { return false }
            // Text directly above the scoreboard column headings is not a player.
            return !cues.contains(where: { abs($0.rect.midY - line.rect.midY) < 0.012 })
        }
        rows.sort { $0.rect.midY > $1.rect.midY }
        guard !rows.isEmpty else { return [] }

        // MWIII scoreboard layout supplied by the user:
        // UPPER BLUE section = player's team; LOWER RED section = opponents.
        // OCR positions use bottom-left coordinates, sorted from top to bottom.
        // Prefer the largest inter-section gap relative to ordinary row spacing
        // instead of an arbitrary fixed 6.5% separation.
        let gaps = zip(rows, rows.dropFirst()).enumerated().map { index, pair in
            (index, pair.0.rect.midY - pair.1.rect.midY)
        }.filter { $0.1 > 0 }
        let sortedSpaces = gaps.map { $0.1 }.sorted()
        let typicalSpacing = sortedSpaces.isEmpty ? 0.0 : sortedSpaces[sortedSpaces.count / 2]
        // Distinct upper and lower team headers give a stronger split than
        // relying on an arbitrary gap between OCR lines.
        let headerYs = headerLines.map { $0.rect.midY }.sorted(by: >)
        let sectionHeaderPair: (upper: CGFloat, lower: CGFloat)? = headerYs.count >= 2 &&
            headerYs[0] - headerYs[1] >= 0.09 ?
            (upper: headerYs[0], lower: headerYs[1]) : nil
        let headerSplit = sectionHeaderPair.flatMap { header -> Int? in
            guard let lastUpper = rows.lastIndex(where: {
                $0.rect.midY < header.upper - 0.012 &&
                $0.rect.midY > header.lower + 0.012
            }), lastUpper >= 1, rows.count - lastUpper - 1 >= 2 else { return nil }
            return lastUpper
        }
        let gapSplit = gaps
            .filter { $0.0 + 1 >= 2 && rows.count - $0.0 - 1 >= 2 }
            .filter { $0.1 >= max(0.026, typicalSpacing * 1.60) }
            .max(by: { $0.1 < $1.1 })?.0
        let validSplit = headerSplit ?? gapSplit
        // If the two colored sections are not visually separable, leave names
        // unclassified. Never silently mark a friendly as an opponent.
        let colors: [RosterSide: String] = [
            .friendly: "#22A8F0", .opponent: "#FF683F", .unknown: "#9A9A9A"
        ]
        var result: [AutoRosterCandidate] = []
        var seen = Set<String>()
        for (index, line) in rows.enumerated() {
            let clean = line.text
                .replacingOccurrences(of: #"^[0-9]{1,3}\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 3 else { continue }
            let key = clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            let side: RosterSide
            if let validSplit {
                // Assign top/bottom based on the common friendly-first HUD
                // layout; users can swap/correct it in the roster view.
                side = index <= validSplit ? .friendly : .opponent
            } else { side = .unknown }
            result.append(AutoRosterCandidate(name: clean, side: side, hex: colors[side]!))
            if result.count == 24 { break }
        }
        return result
    }
}

struct MatchRosterView: View {
    @ObservedObject private var roster = MatchRoster.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("قراءة أسماء الفريقين من لوحة النتائج")
                    .font(.headline)
                Text("أثناء بث PS5 افتح لوحة النتائج في MW3، واضغط «قراءة الفريقين» من شريط البث. تُستخدم قراءة النصوص OCR للأسماء، ويستمر YOLO في كشف أجسام اللاعبين بشكل منفصل.")
                    .font(.footnote)
                Text(roster.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if roster.reading {
                    ProgressView("جارٍ قراءة الأسماء...")
                }
                Text(roster.autoStatus)
                    .font(.caption)
                    .foregroundStyle(.orange)
                ForEach(RosterSide.allCases) { side in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(side.rawValue).font(.headline)
                            Spacer()
                            Text("\(roster.names.filter { $0.side == side }.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ForEach($roster.names) { $entry in
                            if entry.side == side {
                                RosterEntryEditor(entry: $entry) {
                                    let id = entry.id
                                    roster.names.removeAll { $0.id == id }
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                }
                Button("تبديل الفريقين بعد قراءة خاطئة") { roster.swapDetectedSides() }
                    .buttonStyle(.bordered)
                Button("بداية مباراة جديدة", role: .destructive) { roster.reset() }
                    .buttonStyle(.bordered)
                Text("لا يستطيع YOLO تحديد صاحب كل اسم بمجرد قراءة لوحة النتائج. ربط اسم معيّن بمربع لاعب يتطلب ظهور اسمه فوق الجسم في صورة اللعب نفسها.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }.padding(20)
        }
        .navigationTitle("قائمة فريقي والخصوم")
        .environment(\.layoutDirection, .rightToLeft)
    }
}
/// Keep the name/color editor small to avoid complex SwiftUI type-checking in the roster.
private struct RosterEntryEditor: View {
    @Binding var entry: RosterName
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("اسم اللاعب", text: $entry.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(AcidFieldStyle())
                .environment(\.layoutDirection, .leftToRight)
            if let hex = entry.nameColorHEX {
                colorRow(hex)
            }
            HStack {
                Menu {
                    ForEach(RosterSide.allCases) { choice in
                        Button(choice.rawValue) {
                            entry.side = choice
                            entry.isConfirmedByUser = true
                        }
                    }
                } label: {
                    Label(entry.side.rawValue, systemImage: "person.2")
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }.accessibilityLabel("حذف الاسم")
            }
        }
    }

    private func colorRow(_ hex: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(uiColor: UIColor(hexRGB: hex) ?? .gray))
                .frame(width: 13, height: 13)
            Text("لون الاسم: \(hex)")
                .font(.caption)
                .monospaced()
            Spacer()
            Button("استخدام اللون") {
                guard let hue = UIColor(hexRGB: hex)?.hueValue else { return }
                AIAnalysisState.shared.colorHue = hue
                AIAnalysisState.shared.colorMode = true
            }
            .font(.caption)
        }
    }
}



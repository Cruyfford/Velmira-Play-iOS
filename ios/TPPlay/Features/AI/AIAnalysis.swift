import SwiftUI
import CoreVideo
import ImageIO
import PhotosUI
import CoreImage

/// Analysis is independent from controller output; assistance consumes fresh results only.
@MainActor
final class AIAnalysisState: ObservableObject {
    static let shared = AIAnalysisState()
    @Published var colorMode = true { didSet { configure() } }
    @Published var hybridMode = true { didSet { configure() } }
    @Published var adaptiveBodyMarker = true { didSet { configure() } }
    @Published var showPlayerBoxes = true
    @Published var precisionMode = true { didSet { configure() } }
    private var persistence = StableDetectionFilter()
    @Published var colorHue = 0.0 { didSet { configure() } }
    @Published var colorTolerance = 0.045 { didSet { configure() } }
    @Published var enabled = false { didSet { configure() } }
    @Published var threshold = 0.6 { didSet { configure() } }
    @Published var rate = 8.0 { didSet { configure() } }
    @Published private(set) var result: HumanAnalysis?
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
        return true
    }

    func restoreSavedSettings() {
        adaptiveBodyMarker = UserDefaults.standard.object(forKey: adaptiveMarkerKey) as? Bool ?? true
        showPlayerBoxes = UserDefaults.standard.object(forKey: playerBoxesKey) as? Bool ?? true
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
        persistence.reset()
    }
    /// Configure image analysis only; activation of controller assistance stays manual.
    func prepareHybridTracking() {
        colorMode = true
        hybridMode = true
        precisionMode = true
        adaptiveBodyMarker = true
        rate = 12
        enabled = true
    }

    func accept(_ value: HumanAnalysis) {
        let hybrid = true
        guard precisionMode || hybrid else { result = value; return }
        if value.error != nil {
            persistence.reset()
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
    func clear() {
        result = nil
        persistence.reset()
        AIFrameAnalyzer.shared.invalidate()
    }
}
private final class RetainedVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

final class AIFrameAnalyzer: @unchecked Sendable {
    static let shared = AIFrameAnalyzer()
    private let queue = DispatchQueue(label: "app.velmira.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var paused = false
    private var busy = false
    private var generation: UInt64 = 0
    private var threshold: Float = 0.6
    private var rate = 3.0
    private var colorMode = false
    private var hybridMode = true
    private var adaptiveBodyMarker = true
    private var color = ColorTrackingConfiguration()
    private var previousTime: TimeInterval = 0
    func configure(enabled: Bool, threshold: Float, rate: Double, colorMode: Bool,
                   hybridMode: Bool, adaptiveBodyMarker: Bool,
                   color: ColorTrackingConfiguration) {
        lock.lock(); defer { lock.unlock() }
        self.colorMode = colorMode
        self.hybridMode = hybridMode
        self.adaptiveBodyMarker = adaptiveBodyMarker
        self.color = color
        self.enabled = enabled; self.threshold = min(0.95, max(0.2, threshold))
        self.rate = min(12, max(1, rate)); generation &+= 1
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
        lock.unlock()
        let frame = RetainedVideoFrame(pixelBuffer)
        queue.async { [self, frame] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard current(token) else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let size = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
            let report: HumanAnalysis
            do {
                // YOLO processes decoded Remote Play frames using Core ML
                // without Apple Vision. Warm-colored HUD cues are associated
                // with detected bodies, automatically and without manual names.
                let found = try CoreMLYOLODetector.shared.detect(frame.buffer, threshold: minimum)
                let people = found.map(\.box)
                let markers = try ColorTargetDetector.detect(
                    frame.buffer,
                    configuration: ColorTrackingConfiguration(
                        hue: 0.035, tolerance: 0.13,
                        minimumSaturation: 0.55, minimumBrightness: 0.32))
                let detections = HybridTargetFusion.associate(markers: markers, people: people)
                report = HumanAnalysis(detections: detections, imageSize: size, capturedAt: now,
                                       milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                       error: nil, visiblePlayerBoxes: people)
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
                            Rectangle().stroke(Color.green, lineWidth: 2.5)
                                .frame(width: body.width * width, height: body.height * height)
                                .overlay(alignment: .topLeading) {
                                    Text(PlayerVisualCues.proximity(for: body))
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
                        if model.adaptiveBodyMarker, let body = detection.matchedPersonBox {
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
                    Button("تحليل تلقائي: YOLO + علامات الخصوم") { model.prepareHybridTracking() }
                    Toggle("تشغيل تحليل الصورة", isOn: $model.enabled)
                    Text("يتعرف على العلامات الدافئة تلقائياً، دون اختيار لون.")
                    if model.colorMode {
                        Toggle("دمج كشف اللون مع تحليل الأشخاص بالذكاء الاصطناعي", isOn: $model.hybridMode)
                        Text("يشترط لون العلامة مع جسم مكتشف ومطابقة واضحة بينهما. عند فقد أحدهما يتوقف التتبّع؛ لون العلامة لا يثبت الفريق وحده.")
                            .font(.footnote)
                    }
                    Toggle("إظهار مربعات خضراء حول اللاعبين المكتشفين", isOn: $model.showPlayerBoxes)
                    Text("بجانب كل مربع يظهر قرب نسبي (قريب جدًا / قريب / متوسط / بعيد) حسب ارتفاع الجسم في الصورة، وليس مسافة بالمتر. الأجسام المكتشفة قد تشمل لاعبي فريقك.")
                        .font(.footnote)
                    Toggle("إظهار موضع الجسم المختار مع تغير مسافة اللاعب", isOn: $model.adaptiveBodyMarker)
                    Text("في الوضع المدمج تتبع نقطة التصويب الجسم المكتشف وتتكيف مع حجمه. إظهار العلامة خيار مرئي؛ حركة التحكم تحتاج تفعيل المساعدة وL2.")
                        .font(.footnote)
                    Toggle("تقليل الأخطاء — تأكيد عبر الإطارات", isOn: $model.precisionMode)
                    if model.precisionMode {
                        Text("الوضع المدمج يشترط صورتين للتحقق. الأوضاع الأخرى تستخدم 3 صور عند تفعيل هذا الخيار. لا تُرسل حركة نحو هدف غائب.")
                            .font(.footnote).foregroundStyle(.orange)
                        Text("التأكيد لا يثبت أن الشخصية من فريق الخصم. استخدم لون العلامة المميز وراجع النتائج.")
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
                        Text("12 سريع").tag(12.0)
                    }.pickerStyle(.segmented)
                    Text("لا تعني هذه القيم معدل إطارات اللعبة. يُخفَّض التحليل تلقائيًا عند ارتفاع حرارة الجهاز.")
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
                    Text("YOLOv3 Tiny مدرب على COCO وليس MW3؛ قد تفوته الشخصيات الصغيرة. الكشف عن الخصوم من العلامات الدافئة تقديري وغير مضمون.")
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

enum RosterSide: String, CaseIterable, Identifiable, Codable, Sendable {
    case unknown = "غير مصنف", friendly = "فريقي", opponent = "الخصوم"
    var id: String { rawValue }
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
        didSet { saveRoster() }
    }
    @Published var reading = false
    @Published var message = "ابدأ مباراة جديدة ثم أضف صورة لوحة النتائج."
    @Published var matchNumber = 1
    @Published var autoScanEnabled = UserDefaults.standard.object(forKey: "velmira.roster.autoscan.v1") as? Bool ?? true {
        didSet {
            // YOLO does not read names; no OCR scanner is launched.
            if !autoScanEnabled { pending.removeAll() }
        }
    }

    func saveAutoScanSetting() {
        UserDefaults.standard.set(autoScanEnabled, forKey: "velmira.roster.autoscan.v1")
    }

    func restoreAutoScanSetting() {
        autoScanEnabled = UserDefaults.standard.object(forKey: "velmira.roster.autoscan.v1") as? Bool ?? true
    }
    @Published private(set) var autoStatus = "يُراقب الأسماء الملونة أثناء بث PS5 عند تفعيل الاكتشاف."
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
    func read(_ data: Data) async {
        message = "YOLO يكشف الأشخاص، لا نصوص الأسماء؛ الكشف الآلي لا يحتاج أسماء."
    }
}
struct MatchRosterView: View {
    @ObservedObject private var roster = MatchRoster.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("الكشف التلقائي — YOLO").font(.headline)
                Text("يكتشف YOLO الأشخاص، وتحلّل الأداة العلامات الدافئة فوقهم تلقائياً. لا تحتاج إلى إدخال أسماء أو ألوان.")
                Text("هذا تصنيف تقريبي اعتماداً على الشاشة وليس معرفة مؤكدة بالفرق.")
                    .font(.footnote).foregroundStyle(.orange)
                Button("بداية مباراة جديدة", role: .destructive) { roster.reset() }
                    .buttonStyle(.bordered)
            }.padding(20)
        }
        .navigationTitle("تحليل الخصوم")
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



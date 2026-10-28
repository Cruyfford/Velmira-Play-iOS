import SwiftUI
import Vision
import CoreVideo
import ImageIO
import PhotosUI
import CoreImage

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
    @Published var precisionMode = true { didSet { configure() } }
    private var persistence = StableDetectionFilter()
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
        persistence.reset()
    }
    func accept(_ value: HumanAnalysis) {
        guard precisionMode else { result = value; return }
        if value.error != nil {
            persistence.reset()
            result = value
            return
        }
        let confirmations = persistence.update(value.detections.map(\.box), at: value.capturedAt)
        let confirmed = confirmations.map { match -> HumanDetection in
            let item = value.detections[match.index]
            return HumanDetection(id: match.id, box: item.box, confidence: item.confidence)
        }
        result = HumanAnalysis(detections: confirmed, imageSize: value.imageSize,
                               capturedAt: value.capturedAt,
                               milliseconds: value.milliseconds, error: value.error)
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
                        HumanDetection(id: UUID(), box: $0, confidence: 0) // Matching a hue is not a 100% model score.
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
            ScrollView {
                VStack(spacing: 16) {
                NavigationLink { MatchRosterView() } label: {
                    Label("قائمة فريقي والخصوم", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(AcidButtonStyle(active: true))
                VelmiraSection("الذكاء الاصطناعي — معاينة البث") {
                    Toggle("تشغيل تحليل الصورة", isOn: $model.enabled)
                    Toggle("تتبّع لون العلامة بدل كشف الأشخاص", isOn: $model.colorMode)
                    Toggle("تقليل الأخطاء — تأكيد 3 إطارات", isOn: $model.precisionMode)
                    if model.precisionMode {
                        Text("تظهر العلامة فقط بعد تأكيد وجودها في 3 صور متتالية. قد يؤدي ذلك إلى تجاهل الأهداف السريعة.")
                            .font(.footnote).foregroundStyle(.orange)
                        Text("التأكيد لا يثبت أن الشخصية من فريق الخصم. استخدم لون العلامة المميز وراجع النتائج.")
                            .font(.footnote)
                    }
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
                VelmiraSection("الأداء") {
                    Slider(value: $model.threshold, in: 0.2...0.95, step: 0.05) {
                        Text("عتبة الثقة")
                    }
                    Text("عتبة الثقة: \(Int(model.threshold * 100))٪")
                    Picker("معدل التحليل", selection: $model.rate) {
                        Text("3").tag(3.0)
                        Text("5").tag(5.0)
                        Text("8").tag(8.0)
                    }.pickerStyle(.segmented)
                    Text("لا تعني هذه القيم معدل إطارات اللعبة. يُخفَّض التحليل تلقائيًا عند ارتفاع حرارة الجهاز.")
                }
                VelmiraSection("حالة التحليل") {
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
                VelmiraSection("حدود الكشف") {
                    Text("Apple Vision نموذج عام، غير مدرَّب هنا على Call of Duty. قد يفوّت الشخصيات أو يكتشف مناطق خاطئة، ولا يميز الخصم من الصديق أو يؤكد موت الشخصية. درجة الثقة ليست ضمانًا.")
                    Text("دقة 99٪ هدف للاختبار ببيانات حقيقية، وليست نتيجة مثبتة. لتقييم الدقة نحتاج قياس الاكتشافات الصحيحة والمفقودة والخاطئة.")
                    Text("نسخة تطوير: الأداء والاتصال بحاجة لتجربة على iPhone 17 Pro وPS5.")
                }
            }
                .padding(20)
            }
            .background(TPPlayTheme.canvas)
            .navigationTitle("الذكاء الاصطناعي")
            .navigationBarTitleDisplayMode(.inline)
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
            UserDefaults.standard.set(autoScanEnabled, forKey: "velmira.roster.autoscan.v1")
            AutoRosterScanner.shared.configure(enabled: autoScanEnabled)
            if !autoScanEnabled { pending.removeAll() }
        }
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
            if confirmed.side == .opponent, let color = UIColor(hexRGB: confirmed.hex) {
                // Select marker hue only. Never arm assistance or initiate controller actions.
                let ai = AIAnalysisState.shared
                if !ai.colorMode { ai.colorMode = true }
                if abs(ai.colorHue - color.hueValue) > 0.008 { ai.colorHue = color.hueValue }
            }
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
        guard !reading else { return }
        reading = true
        let token = UUID()
        generation = token
        message = "جارٍ قراءة النصوص محلياً…"
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true
                try VNImageRequestHandler(data: data, options: [:]).perform([request])
                var seen = Set<String>()
                let names = (request.results ?? []).compactMap { observation -> String? in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= 0.55 else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 2, text.count <= 64,
                          text.rangeOfCharacter(from: .letters) != nil,
                          seen.insert(text.lowercased()).inserted else { return nil }
                    return text
                }
                return .success(names)
            } catch { return .failure(error) }
        }.value
        guard generation == token else { return }
        reading = false
        switch result {
        case .success(let values):
            let existing = Set(names.map { $0.name.lowercased() })
            names.append(contentsOf: values.filter { !existing.contains($0.lowercased()) }.map { RosterName(name: $0) })
            message = values.isEmpty ? "لم تُقرأ أسماء واضحة. استخدم صورة أوضح." : "راجع النصوص: قد تتضمن عناوين وإحصاءات. صحّح الأسماء وحدد الفريق لكل اسم."
        case .failure(let error):
            message = "تعذرت القراءة: " + error.localizedDescription
        }
    }
}
struct MatchRosterView: View {
    @ObservedObject private var roster = MatchRoster.shared
    @State private var photo: PhotosPickerItem?
    @State private var showReset = false
    @State private var newName = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VelmiraSection("قائمة المباراة \(roster.matchNumber)") {
                    Text("قراءة أسماء لوحة النتائج بالذكاء الاصطناعي على جهازك.")
                    Toggle("التقاط أسماء اللاعبين تلقائيًا أثناء بث PS5", isOn: $roster.autoScanEnabled)
                    Text("الأحمر الغامق = الخصوم، الأزرق = فريقي. يتطلب تكرار الاسم في لقطتين على الأقل؛ التصنيف تقريبي ويحتاج مراجعة.")
                        .font(.footnote).foregroundStyle(.orange)
                    Text(roster.autoStatus).font(.footnote)
                    Text("بدء مباراة جديدة لا يُكتشف تلقائيًا بعد؛ استخدم زر مسح القائمتين عند تغيير المباراة.")
                        .font(.footnote)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("قراءة صورة لوحة النتائج", systemImage: "text.viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(AcidButtonStyle(active: true)).disabled(roster.reading)
                    if roster.reading { ProgressView() }
                    Text(roster.message).font(.footnote)
                    Button("مباراة جديدة — مسح القائمتين", role: .destructive) { showReset = true }
                }
                ForEach(RosterSide.allCases) { side in
                    VelmiraSection("\(side.rawValue) • \(roster.names.filter { $0.side == side }.count)") {
                        if !roster.names.contains(where: { $0.side == side }) {
                            Text("لا توجد أسماء").font(.footnote)
                        }
                        ForEach($roster.names) { $entry in
                            if entry.side == side {
                                RosterEntryEditor(entry: $entry) {
                                    roster.names.removeAll { $0.id == entry.id }
                                }
                            }
                        }
                    }
                }
                VelmiraSection("إضافة اسم يدوياً") {
                    TextField("اسم اللاعب", text: $newName).textFieldStyle(AcidFieldStyle())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("إضافة للمراجعة") {
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { roster.names.append(RosterName(name: name)); newName = "" }
                    }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
        .background(TPPlayTheme.canvas)
        .navigationTitle("الفريق والخصوم")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .rightToLeft)
        .confirmationDialog("مسح جميع أسماء المباراة السابقة؟", isPresented: $showReset, titleVisibility: .visible) {
            Button("بدء مباراة جديدة", role: .destructive) { roster.reset() }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) { await roster.read(data) }
                    else { roster.message = "تعذر تحميل الصورة." }
                } catch { roster.message = "تعذر تحميل الصورة: " + error.localizedDescription }
                photo = nil
            }
        }
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

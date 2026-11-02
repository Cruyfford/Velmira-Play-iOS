import SwiftUI
import GameController
import CoreVideo
import CoreImage
import UIKit

@MainActor
final class AssistanceState: ObservableObject {
    static let shared = AssistanceState()
    @Published var armed = false {
        didSet { if armed { lastStopReason = nil } }
    }
    @Published private(set) var lastStopReason: String?
    // Edit in memory. Only the Save Settings button commits the configuration.
    @Published var configuration: AssistanceConfiguration
    @Published private(set) var target: CGPoint?
    @Published private(set) var status = "متوقف"
    private init() {
        if let data = UserDefaults.standard.data(forKey: "velmira.assistance.v1"),
           let value = try? JSONDecoder().decode(AssistanceConfiguration.self, from: data) {
            configuration = value
        } else { configuration = AssistanceConfiguration() }
    }
    @discardableResult
    func saveSettings() -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        UserDefaults.standard.set(data, forKey: "velmira.assistance.v1")
        return true
    }

    func restoreSavedSettings() {
        if let data = UserDefaults.standard.data(forKey: "velmira.assistance.v1"),
           let saved = try? JSONDecoder().decode(AssistanceConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = AssistanceConfiguration()
        }
    }
    func report(target: CGPoint?, status: String) {
        if self.target != target { self.target = target }
        if self.status != status { self.status = status }
    }
    func emergencyStop(reason: String = "تم إيقاف المساعدة") {
        armed = false
        lastStopReason = reason
        target = nil
        status = "متوقف"
    }
}

struct AssistanceSettings: View {
    @ObservedObject private var model = AssistanceState.shared
    @ObservedObject private var vision = AIAnalysisState.shared
    @State private var savedNotice = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                VelmiraSection("التحكم الفعلي — تجريبي") {
                    Toggle("تفعيل مساعدة التصويب", isOn: $model.armed)
                    Text("بعد التفعيل اترك L2 وR2 أولًا. في وضع القفل المستمر يعمل الكشف مع L2 وبدونه. حرّك العصا بقوة لاستعادة أولوية التحكم اليدوي.")
                    Button("إيقاف جميع المساعدات", role: .destructive) { model.emergencyStop() }
                    Text(model.status)
                    if !model.armed, let reason = model.lastStopReason {
                        Text("سبب الإيقاف: \(reason)")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("YOLOv8n الجديد بدقة 640 يعمل محلياً دون اختيار الأسماء أو الألوان. وقد يخطئ في تصنيف اللاعبين، ولم يُختبر على PS5 بعد.").font(.footnote)
                }
                VelmiraSection("التتبّع") {
                    Toggle("حماية فريقي — التتبع على خصم مؤكّد فقط", isOn: $vision.protectTeammates)
                    Text("تفعيل الحماية يمنع أي تحريك نحو الحلفاء أو اللاعبين المجهولين. لا يحدث قفل تلقائي دون تطابق اسم الخصم فوق رأسه مع قائمة الخصوم الحالية؛ القراءة غير المؤكدة تعني عدم التتبع.")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("تشغيل نموذج MW3 YOLOv8n المدرّب") {
                        model.emergencyStop(reason: "فعّل المساعدة بعد ضبط نموذج YOLOv8n")
                        vision.prepareHybridTracking()
                        model.configuration.tracking = true
                        model.configuration.pointX = 0.5
                        model.configuration.pointY = 0.5
                        savedNotice = "YOLOv8n يكتشف فئة Enemy تلقائياً. احفظ الإعدادات وفعّل المساعدة."
                    }
                    Button("قفل قوي وسريع — YOLOv8n") {
                        model.emergencyStop(reason: "أعد تفعيل المساعدة بعد تطبيق القفل القوي")
                        vision.prepareHybridTracking()
                        vision.threshold = 0.30
                        vision.rate = 20 // Target rate, not a guaranteed measured FPS.
                        model.configuration.tracking = true
                        model.configuration.strongLock = true
                        model.configuration.trackingWithoutL2 = true
                        model.configuration.fullScreenAcquisition = true
                        model.configuration.switchOnLoss = true
                        model.configuration.strength = 3.2
                        model.configuration.maxStick = 0.72
                        model.configuration.response = 0.025
                        model.configuration.staleAfter = 0.28
                        model.configuration.lossDelay = 0.35
                        model.configuration.manualOverride = 0.55
                        model.configuration.radius = 0.42
                        model.configuration.pointX = 0.5
                        model.configuration.pointY = 0.22
                        model.configuration.quickScope = false
                        model.configuration.silentShot = false
                        savedNotice = "تم تفعيل إعداد القفل القوي. احفظ الإعدادات وفعّل المساعدة يدوياً. الأداء يتوقف على كشف YOLO وتأخير الاتصال."
                    }
                    .buttonStyle(.borderedProminent)
                    Button("قفل مستمر على الهدف — مع L2 وبدونه") {
                        model.emergencyStop(reason: "فعّل المساعدة يدوياً بعد ضبط القفل المستمر")
                        vision.prepareHybridTracking()
                        vision.rate = 12
                        model.configuration.tracking = true
                        model.configuration.strength = 2.4
                        model.configuration.maxStick = 0.60
                        model.configuration.trackingWithoutL2 = true
                        model.configuration.fullScreenAcquisition = true
                        model.configuration.switchOnLoss = true
                        model.configuration.lossDelay = 0.5
                        model.configuration.staleAfter = 0.35
                        model.configuration.response = 0.04
                        model.configuration.radius = 0.35
                        savedNotice = "تم ضبط القفل المستمر. احفظ الإعدادات، ثم فعّل المساعدة. الكشف لا يضمن تتبع لاعب خارج الشاشة."
                    }
                    .buttonStyle(.borderedProminent)
                    Button("وضع التتبّع السريع والانتقال للهدف القريب") {
                        model.emergencyStop(reason: "أعد تفعيل المساعدة يدويًا بعد تغيير إعدادات التتبّع")
                        vision.prepareHybridTracking()
                        vision.rate = 12
                        model.configuration.tracking = true
                        model.configuration.switchOnLoss = true
                        model.configuration.lossDelay = 0.15
                        model.configuration.staleAfter = 0.20
                        model.configuration.response = 0.04
                        model.configuration.radius = 0.30
                        savedNotice = "تم ضبط الاستجابة السريعة مؤقتًا. اضغط حفظ الإعدادات وفعّل المساعدة يدويًا."
                    }
                    .buttonStyle(.borderedProminent)
                    Text("يحافظ على هوية الهدف المؤكد حتى لو تحرك خارج نطاق الالتقاط الأولي، ويتحول إلى أقرب هدف مؤكّد من موقعه السابق عند فقده. اختفاء الهدف لا يثبت موته؛ لا يتحرك التصويب إلى هدف غير مرئي. تحليل 12 مرة/ثانية معدل مطلوب وليس أداءً مضمونًا.")
                        .font(.footnote)
                    Text("مع حماية الفريق المفعّلة، فئة Enemy وحدها لا تكفي؛ يلزم تطابق اسم الخصم المقروء فوق رأسه.")
                        .font(.footnote)
                    Toggle("تحريك التصويب نحو الهدف", isOn: $model.configuration.tracking)
                    Toggle("الاستمرار في قفل الهدف بدون L2",
                           isOn: Binding(
                               get: { model.configuration.trackingWithoutL2 ?? false },
                               set: { model.configuration.trackingWithoutL2 = $0 }
                           ))
                    Toggle("قفل قوي: استجابة أسرع وتقدّم محدود لحركة الهدف",
                           isOn: Binding(
                               get: { model.configuration.strongLock ?? false },
                               set: { model.configuration.strongLock = $0 }
                           ))
                    Toggle("البحث عن الأهداف في كامل الشاشة",
                           isOn: Binding(
                               get: { model.configuration.fullScreenAcquisition ?? false },
                               set: { model.configuration.fullScreenAcquisition = $0 }
                           ))
                    Text("الاستمرار دون L2 لا يُفعَّل إلا باختيارك. لا يتحرك التصويب على بيانات قديمة، ولا يمكن الاحتفاظ بهدف غير مرئي.")
                        .font(.footnote)
                    if !vision.enabled {
                        Button("تشغيل تحليل الصورة") { vision.enabled = true }
                    }
                    valueSlider("نطاق الاختيار", value: $model.configuration.radius, range: 0.05...0.5)
                    valueSlider("قوة التصحيح", value: $model.configuration.strength, range: 0.1...5)
                    valueSlider("حد حركة العصا", value: $model.configuration.maxStick, range: 0.02...0.8)
                    valueSlider("زمن التنعيم", value: $model.configuration.response, range: 0.02...0.5)
                    Toggle("عكس المحور الرأسي", isOn: $model.configuration.invertY)
                    Toggle("الانتقال لهدف آخر عند اختفاء الحالي", isOn: $model.configuration.switchOnLoss)
                    valueSlider("مهلة فقد الهدف بالثواني", value: $model.configuration.lossDelay, range: 0.15...2)
                    Text("في وضع L2 التقليدي، قد يلزم ترك L2 عند فقدان الهدف. أما القفل المستمر فيسمح باكتساب هدف مؤكد جديد بعد مهلة الفقد، دون تحريك التصويب على صورة قديمة.").font(.footnote)
                }
                VelmiraSection("نموذج كشف MW3") {
                    Text("تستخدم النسخة المدرّبة YOLOv8n (فئة Enemy واحدة) من دون إدخال أسماء اللاعبين أو ألوانهم.")
                        .font(.footnote)
                    Text("تقييم الاختبار الجديد بدقة 640: mAP@50 نحو 79.5٪ على 21 صورة فقط. قد يفقد اللاعب البعيد أو يخلط الحلفاء بالأعداء؛ هذه ليست دقة مضمونة داخل اللعبة.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                VelmiraSection("موضع التصويب داخل الجسم") {
                    HStack {
                        Button("الرأس") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.1 }
                        Button("البطن") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.55 }
                        Button("الرجل") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.88 }
                    }.buttonStyle(.bordered)
                    BodyPointPicker(x: $model.configuration.pointX, y: $model.configuration.pointY, hue: vision.colorHue)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ضبط دقيق لموضع النقطة")
                            .font(.headline)
                            .foregroundStyle(.cyan)
                        Text("اسحب النقطة على الجسم، أو اضبط المحورين أدناه بدقة 1٪. كل تغيير يظهر على الرسم مباشرة.")
                            .font(.footnote)
                        HStack {
                            Text("أفقي (X)")
                            Spacer()
                            Text("\(Int((model.configuration.pointX * 100).rounded()))٪")
                                .monospacedDigit()
                                .foregroundStyle(.cyan)
                        }
                        Slider(value: $model.configuration.pointX, in: 0...1, step: 0.01)
                            .tint(.cyan)
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityLabel("ضبط الموضع الأفقي")
                        HStack(spacing: 12) {
                            Button {
                                model.configuration.pointX = max(0, (model.configuration.pointX * 100 - 1).rounded() / 100)
                            } label: {
                                Label("يسار 1٪", systemImage: "arrow.left")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                model.configuration.pointX = min(1, (model.configuration.pointX * 100 + 1).rounded() / 100)
                            } label: {
                                Label("يمين 1٪", systemImage: "arrow.right")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        HStack {
                            Text("رأسي (Y)")
                            Spacer()
                            Text("\(Int((model.configuration.pointY * 100).rounded()))٪")
                                .monospacedDigit()
                                .foregroundStyle(.cyan)
                        }
                        Slider(value: $model.configuration.pointY, in: 0...1, step: 0.01)
                            .tint(.cyan)
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityLabel("ضبط الموضع الرأسي")
                        HStack(spacing: 12) {
                            Button {
                                model.configuration.pointY = max(0, (model.configuration.pointY * 100 - 1).rounded() / 100)
                            } label: {
                                Label("أعلى 1٪", systemImage: "arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                model.configuration.pointY = min(1, (model.configuration.pointY * 100 + 1).rounded() / 100)
                            } label: {
                                Label("أسفل 1٪", systemImage: "arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    Toggle("إظهار النقطة المحددة على جسم اللاعب تلقائيًا", isOn: $vision.adaptiveBodyMarker)
                    Text("اختر الرأس أو البطن أو الرجل، أو اسحب النقطة إلى موضع مخصص. إذا أمكن ربط الاسم الملون بشخص ظاهر، تتحرك نقطة المعاينة مع جسمه وتتكيف مع حجمه عند الاقتراب والابتعاد. عند عدم التعرف على الشخص لن يظهر موضع متخيل.")
                        .font(.footnote)
                    Button {
                        if model.saveSettings() && vision.saveSettings() {
                            savedNotice = "تم حفظ موضع النقطة وخيار التتبع المرئي."
                        } else {
                            savedNotice = "تعذر حفظ إعدادات موضع النقطة."
                        }
                    } label: {
                        Label("حفظ موضع النقطة", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))
                    if !savedNotice.isEmpty {
                        Text(savedNotice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                VelmiraSection("إذا كان اللون فوق الرأس") {
                    valueSlider("الإزاحة الأفقية من الاسم", value: $model.configuration.colorOffsetX, range: -0.3...0.3)
                    valueSlider("الإزاحة أسفل الاسم", value: $model.configuration.colorOffsetY, range: -0.1...0.4)
                    Text("هذه الإزاحة لوضع اللون وحده. الوضع المدمج يستخدم موضع التصويب داخل الجسم ويتكيف مع حجمه.").font(.footnote)
                }
                VelmiraSection("السنايبر — مرة لكل ضغطة L2") {
                    Toggle("Quick Scope: تصويب ثم R2", isOn: $model.configuration.quickScope)
                    valueSlider("التأخير قبل الطلقة", value: $model.configuration.scopeDelay, range: 0.05...2)
                    valueSlider("مدة ضغط R2", value: $model.configuration.shotDuration, range: 0.03...0.3)
                    Toggle("Silent Shot: طلقة ثم تبديل السلاح", isOn: $model.configuration.silentShot)
                    valueSlider("تأخير تبديل السلاح", value: $model.configuration.switchDelay, range: 0.03...1)
                    valueSlider("مدة ضغط زر المثلث", value: $model.configuration.switchDuration, range: 0.03...0.3)
                    Text("التبديل يضغط مثلث وفق ترتيب أزرار اللعبة الافتراضي. الاسم هنا يعني تسلسل أزرار فقط، ولا يضمن إخفاء صوت الطلقة. ترك L2 يلغي التسلسل. الماكرو لا ينتظر كشف هدف.").font(.footnote)
                }
                VelmiraSection("تعويض الارتداد — L2 مع R2") {
                    Toggle("تعويض ثابت قابل للمعايرة", isOn: $model.configuration.recoil)
                    valueSlider("أفقي", value: $model.configuration.recoilX, range: -0.3...0.3)
                    valueSlider("رأسي", value: $model.configuration.recoilY, range: -0.3...0.3)
                    Text("ليس تثبيتًا مضمونًا لكل سلاح. اضبطه لكل حساسية وسلاح داخل ساحة تدريب.").font(.footnote)
                }
                VelmiraSection("حفظ إعدادات التحكم") {
                    Button {
                        if model.saveSettings() && vision.saveSettings() {
                            savedNotice = "تم حفظ إعدادات التحكم واللون. ستعود كما هي بعد إعادة تشغيل البرنامج."
                        } else {
                            savedNotice = "تعذر حفظ الإعدادات. حاول مجددًا."
                        }
                    } label: {
                        Label("حفظ الإعدادات", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))
                    Text(savedNotice.isEmpty ? "التغييرات مؤقتة حتى تضغط حفظ الإعدادات." : savedNotice)
                        .font(.footnote)
                    Button("استعادة آخر إعدادات محفوظة") {
                        model.emergencyStop()
                        model.restoreSavedSettings()
                        vision.restoreSavedSettings()
                        savedNotice = "تم استعادة آخر إعدادات محفوظة."
                    }
                    Button("استعادة القيم الافتراضية", role: .destructive) {
                        model.emergencyStop(); model.configuration = AssistanceConfiguration()
                    }
                    Text("تُحفظ الإعدادات بالزر أعلاه فقط. تفعيل المساعدة أثناء اللعب يبقى إجراءً يدويًا.")
                }
            }
                .padding(20)
            }
            .background(TPPlayTheme.canvas)
            .navigationTitle("التحكم والمساعدة")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                model.restoreSavedSettings()
                vision.restoreSavedSettings()
            }
            .toolbarBackground(TPPlayTheme.canvas, for: .navigationBar)
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(value.wrappedValue, specifier: "%.2f")")
            Slider(value: value, in: range)
        }
    }
}

private struct BodyPointPicker: View {
    @Binding var x: Double
    @Binding var y: Double
    let hue: Double
    var body: some View {
        GeometryReader { geometry in
            let bodyHeight = geometry.size.height - 92
            let bodyWidth = min(geometry.size.width - 48, bodyHeight * 0.54)
            let bodyLeft = (geometry.size.width - bodyWidth) / 2
            let bodyTop: CGFloat = 76
            let markerColor = Color(hue: hue, saturation: 0.85, brightness: 0.95)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.25))
                Text("ENEMY_01").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(markerColor)
                    .position(x: geometry.size.width / 2, y: 22)
                Circle().fill(markerColor).frame(width: 10, height: 10)
                    .overlay { Circle().stroke(Color.white.opacity(0.7), lineWidth: 1) }
                    .position(x: geometry.size.width / 2, y: 46)
                Image(systemName: "figure.stand")
                    .resizable().scaledToFit().foregroundStyle(.gray)
                    .frame(width: bodyWidth, height: bodyHeight)
                    .position(x: geometry.size.width / 2, y: bodyTop + bodyHeight / 2)
                Circle().stroke(Color.cyan, lineWidth: 3).frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.2)))
                    .position(x: bodyLeft + x * bodyWidth, y: bodyTop + y * bodyHeight)
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .frame(width: bodyWidth, height: bodyHeight)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        x = min(1, max(0, value.location.x / bodyWidth))
                        y = min(1, max(0, value.location.y / bodyHeight))
                    })
                    .offset(x: bodyLeft, y: bodyTop)
            }
        }.frame(height: 350).environment(\.layoutDirection, .leftToRight)
    }
}

struct GameProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var assistance: AssistanceConfiguration
    var hue: Double
    var tolerance: Double
    var colorMode: Bool
    var threshold: Double
    var rate: Double
    var resolution: Int
    var fps: Int
    var bitrate: Int
}
@MainActor
final class GameProfiles: ObservableObject {
    static let shared = GameProfiles()
    @Published var profiles: [GameProfile] = []
    @Published var message = ""
    @Published private(set) var hasPendingAppliedProfile = false
    private var pendingQuality: (resolution: Int, fps: Int, bitrate: Int)?
    private let key = "velmira.gameProfiles.v1"
    init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            do { profiles = try JSONDecoder().decode([GameProfile].self, from: data) }
            catch { message = "تعذر قراءة ملفات الإعدادات المحفوظة." }
        }
    }
    private func persist() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(profiles), forKey: key) }
        catch { message = "تعذر حفظ الإعدادات." }
    }
    func save(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { message = "اسم الملف يجب أن يكون بين 1 و80 حرفاً"; return }
        let ai = AIAnalysisState.shared
        let defaults = UserDefaults.standard
        if let index = profiles.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
            profiles.remove(at: index)
        } else if profiles.count >= 40 {
            message = "بلغت الحد الأقصى (40 ملفاً). احذف ملفاً قديماً أولاً."
            return
        }
        profiles.append(GameProfile(name: clean, assistance: AssistanceState.shared.configuration,
            hue: ai.colorHue, tolerance: ai.colorTolerance, colorMode: ai.colorMode,
            threshold: ai.threshold, rate: ai.rate,
            resolution: pendingQuality?.resolution ?? (defaults.object(forKey: "streamResolution") as? Int ?? 1080),
            fps: pendingQuality?.fps ?? (defaults.object(forKey: "streamFPS") as? Int ?? 60),
            bitrate: pendingQuality?.bitrate ?? (defaults.object(forKey: "streamBitrate") as? Int ?? 15000)))
        message = "تم حفظ ملف جديد."
        persist()
    }
    func apply(_ profile: GameProfile) {
        AssistanceState.shared.emergencyStop()
        AssistanceState.shared.configuration = profile.assistance
        let ai = AIAnalysisState.shared
        ai.enabled = false
        ai.colorHue = profile.hue; ai.colorTolerance = profile.tolerance
        ai.colorMode = profile.colorMode; ai.threshold = profile.threshold; ai.rate = profile.rate
        pendingQuality = (profile.resolution, profile.fps, profile.bitrate)
        hasPendingAppliedProfile = true
        message = "تم تحميل «\(profile.name)» مؤقتًا. اضغط حفظ الإعدادات لتثبيته؛ المساعدة متوقفة."
    }

    @discardableResult
    func saveCurrentSettings() -> Bool {
        guard AssistanceState.shared.saveSettings(),
              AIAnalysisState.shared.saveSettings() else {
            message = "تعذر حفظ إعدادات اللعبة."
            return false
        }
        if let pendingQuality {
            let defaults = UserDefaults.standard
            defaults.set(pendingQuality.resolution, forKey: "streamResolution")
            defaults.set(pendingQuality.fps, forKey: "streamFPS")
            defaults.set(pendingQuality.bitrate, forKey: "streamBitrate")
        }
        pendingQuality = nil
        hasPendingAppliedProfile = false
        message = "تم حفظ الإعدادات المطبقة بشكل دائم."
        return true
    }

    func discardUnsavedProfile() {
        guard hasPendingAppliedProfile else { return }
        pendingQuality = nil
        hasPendingAppliedProfile = false
        AssistanceState.shared.restoreSavedSettings()
        AIAnalysisState.shared.restoreSavedSettings()
        message = "تم إلغاء تطبيق ملف الإعدادات غير المحفوظ."
    }

    func remove(_ id: UUID) { profiles.removeAll { $0.id == id }; persist() }
}
struct VelmiraToolsView: View {
    @ObservedObject private var profiles = GameProfiles.shared
    @State private var showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
    @State private var toolsNotice = ""
    @State private var name = ""
    @State private var deleteID: UUID?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VelmiraSection("أدوات البث") {
                        Toggle("عرض لوحة الأداء أثناء البث", isOn: $showMetrics)
                        Button {
                            if profiles.saveCurrentSettings() {
                                UserDefaults.standard.set(showMetrics, forKey: "velmira.showMetrics.compact.v2")
                                toolsNotice = "تم حفظ إعدادات الأدوات وملف اللعبة المطبق."
                            } else {
                                toolsNotice = "تعذر حفظ بعض الإعدادات."
                            }
                        } label: {
                            Label("حفظ إعدادات الأدوات", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(AcidButtonStyle(active: true))
                        Button("استعادة آخر إعدادات محفوظة") {
                            showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
                            toolsNotice = "تم استعادة القيم المحفوظة."
                        }
                        Text(toolsNotice.isEmpty ? "يجب الضغط على حفظ لتثبيت أي تعديل." : toolsNotice)
                            .font(.footnote)
                        Text("داخل شاشة PS5 اضغط «معايرة»: اختر لون الاسم، ثم موضع التصويب على لقطة ثابتة. يمكنك حفظ اللون وحده أو حفظ النقطتين.")
                            .font(.footnote)
                        Text("زر إيقاف المساعدات يبقى ظاهراً داخل البث.").font(.footnote)
                    }
                    NavigationLink { ControllerTestView() } label: {
                        Label("اختبار يد التحكم", systemImage: "gamecontroller")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }.buttonStyle(AcidButtonStyle(active: true))
                    VelmiraSection("ملفات إعدادات الألعاب") {
                        TextField("اسم اللعبة أو ملف الإعدادات", text: $name).textFieldStyle(AcidFieldStyle())
                        Button("حفظ الإعدادات الحالية كملف جديد") { profiles.save(name); name = "" }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("يحفظ اللون، إعدادات التحليل، حساسية المساعدة، الماكروز وجودة البث. لا يحفظ بيانات حسابك أو صور البث.")
                            .font(.footnote)
                        Text(profiles.message).font(.footnote)
                    }
                    ForEach(profiles.profiles) { profile in
                        VelmiraSection(profile.name) {
                            HStack {
                                Button("تطبيق") { profiles.apply(profile) }
                                Spacer()
                                Button("حذف", role: .destructive) { deleteID = profile.id }
                            }
                        }
                    }
                }.padding(20)
            }.background(TPPlayTheme.canvas)
                .navigationTitle("الأدوات").navigationBarTitleDisplayMode(.inline)
                .confirmationDialog("حذف ملف الإعدادات؟", isPresented: Binding(
                    get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
                    Button("حذف", role: .destructive) {
                        if let id = deleteID { profiles.remove(id) }
                        deleteID = nil
                    }
                }
        }.environment(\.layoutDirection, .rightToLeft)
        .onDisappear {
            showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
            profiles.discardUnsavedProfile()
        }
    }
}
struct ControllerTestView: View {
    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                VStack(spacing: 16) {
                    Text("اختبار محلي فقط؛ لا يرسل أوامر إلى PS5.").font(.footnote)
                    if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
                       let pad = controller.extendedGamepad {
                        VelmiraSection(controller.vendorName ?? "يد تحكم متصلة") {
                            Text(pad is GCDualSenseGamepad ? "DualSense متصلة" : "يد تحكم متصلة")
                            trigger("L2", value: pad.leftTrigger.value)
                            trigger("R2", value: pad.rightTrigger.value)
                            stick("العصا اليسرى", input: pad.leftThumbstick)
                            stick("العصا اليمنى", input: pad.rightThumbstick)
                            HStack {
                                key("✕", pressed: pad.buttonA.isPressed)
                                key("○", pressed: pad.buttonB.isPressed)
                                key("□", pressed: pad.buttonX.isPressed)
                                key("△", pressed: pad.buttonY.isPressed)
                            }
                            HStack {
                                key("L1", pressed: pad.leftShoulder.isPressed)
                                key("R1", pressed: pad.rightShoulder.isPressed)
                                key("L3", pressed: pad.leftThumbstickButton?.isPressed ?? false)
                                key("R3", pressed: pad.rightThumbstickButton?.isPressed ?? false)
                            }
                        }
                    } else {
                        VelmiraSection("لا توجد يد متصلة") {
                            Text("اربط يد DualSense بالآيفون من إعدادات Bluetooth ثم عد إلى هذه الصفحة.")
                        }
                    }
                }.padding(20)
            }
        }.background(TPPlayTheme.canvas)
            .navigationTitle("اختبار اليد").navigationBarTitleDisplayMode(.inline)
    }
    private func trigger(_ title: String, value: Float) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value * 100))٪").monospacedDigit()
            ProgressView(value: Double(value)).tint(.cyan)
        }
    }
    private func stick(_ title: String, input: GCControllerDirectionPad) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(String(format: "X: %.2f   Y: %.2f", input.xAxis.value, input.yAxis.value))
                .monospacedDigit().environment(\.layoutDirection, .leftToRight)
        }
    }
    private func key(_ title: String, pressed: Bool) -> some View {
        Text(title).frame(maxWidth: .infinity, minHeight: 42)
            .background(pressed ? Color.cyan : TPPlayTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(pressed ? Color.black : Color.white)
    }
}

// Retain one decoded frame only. Conversion happens on demand, never per frame.
final class CalibrationFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var capturedAt: TimeInterval = 0
    private var closed = false
    func accept(_ value: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        frame = value; capturedAt = ProcessInfo.processInfo.systemUptime
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        closed = true; frame = nil
    }
    func image() -> CGImage? {
        lock.lock()
        let current = frame
        let fresh = ProcessInfo.processInfo.systemUptime - capturedAt < 1
        lock.unlock()
        guard fresh, let current else { return nil }
        let image = CIImage(cvPixelBuffer: current)
        return CIContext().createCGImage(image, from: image.extent)
    }
}
struct CalibrationShot: Identifiable {
    let id = UUID()
    let image: CGImage
}
struct StreamCalibrationView: View {
    let shot: CalibrationShot
    @Environment(\.dismiss) private var dismiss
    @State private var marker: CGPoint?
    @State private var aim: CGPoint?
    @State private var hue: Double?
    @State private var editingMarker = true
    @State private var message = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("لقطة ثابتة من بثك • إدخال التحكم متوقف حتى إغلاق المعايرة.")
                        .font(.footnote)
                    Picker("النقطة", selection: $editingMarker) {
                        Text("١ • الاسم واللون").tag(true)
                        Text("٢ • موضع التصويب").tag(false)
                    }.pickerStyle(.segmented)
                    GeometryReader { geo in
                        let ratio = CGFloat(shot.image.width) / CGFloat(shot.image.height)
                        let width = min(geo.size.width, geo.size.height * ratio)
                        let height = width / ratio
                        let left = (geo.size.width - width) / 2
                        let top = (geo.size.height - height) / 2
                        ZStack(alignment: .topLeading) {
                            Color.black
                            Image(decorative: shot.image, scale: 1)
                                .resizable().frame(width: width, height: height).offset(x: left, y: top)
                            if let marker {
                                Circle().stroke(Color.red, lineWidth: 3).frame(width: 24, height: 24)
                                    .position(x: left + marker.x * width, y: top + marker.y * height)
                            }
                            if let aim {
                                Circle().stroke(Color.cyan, lineWidth: 3).frame(width: 24, height: 24)
                                    .position(x: left + aim.x * width, y: top + aim.y * height)
                            }
                            if let marker, let aim {
                                Path { path in
                                    path.move(to: CGPoint(x: left + marker.x * width, y: top + marker.y * height))
                                    path.addLine(to: CGPoint(x: left + aim.x * width, y: top + aim.y * height))
                                }.stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            }
                        }.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                guard width > 0, height > 0,
                                      value.location.x >= left, value.location.x <= left + width,
                                      value.location.y >= top, value.location.y <= top + height else { return }
                                let point = CGPoint(x: (value.location.x - left) / width, y: (value.location.y - top) / height)
                                if editingMarker { marker = point; hue = sampleHue(point) }
                                else { aim = point }
                            })
                    }.frame(height: 300).environment(\.layoutDirection, .leftToRight)
                    Text("المس حرفاً ملوناً قرب منتصف الاسم، ثم اختر النقطة الثانية وضعها على الجسم. يمكنك سحب كل نقطة بعد اختيارها.")
                        .font(.footnote)
                    if let hue {
                        RoundedRectangle(cornerRadius: 8).fill(Color(hue: hue, saturation: 1, brightness: 1)).frame(height: 24)
                    }
                    Text(message).font(.footnote).foregroundStyle(.orange)
                    Button("حفظ اللون فقط") { save(includeOffset: false) }
                        .frame(maxWidth: .infinity, minHeight: 48).buttonStyle(AcidButtonStyle())
                        .disabled(hue == nil)
                    Button("حفظ اللون ومعايرة النقطتين") { save(includeOffset: true) }
                        .frame(maxWidth: .infinity, minHeight: 48).buttonStyle(AcidButtonStyle(active: true))
                        .disabled(hue == nil || marker == nil || aim == nil)
                    Text("للوضع المدمج احفظ اللون وحده واختر موضع التصويب داخل الجسم من الإعدادات. النقطتان تضبطان إزاحة وضع اللون وحده. الحفظ لا يفعّل المساعدات.")
                        .font(.footnote)
                }.padding(20)
            }.background(TPPlayTheme.canvas)
                .navigationTitle("اللون والمعايرة").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }.environment(\.layoutDirection, .rightToLeft)
    }
    private func sampleHue(_ point: CGPoint) -> Double? {
        let x = min(shot.image.width - 1, max(0, Int(point.x * CGFloat(shot.image.width))))
        let y = min(shot.image.height - 1, max(0, Int(point.y * CGFloat(shot.image.height))))
        guard let pixel = shot.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        guard ok else { return nil }
        let color = UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                            blue: CGFloat(bytes[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s >= 0.65, b >= 0.45 else {
            message = "النقطة داكنة جداً أو قليلة اللون؛ المس حرفاً ملوناً من الاسم."
            return nil
        }
        message = ""
        return Double(h)
    }
    private func save(includeOffset: Bool) {
        guard let hue else { return }
        if includeOffset {
            guard let marker, let aim else { return }
            let dx = Double(aim.x - marker.x), dy = Double(aim.y - marker.y)
            guard (-0.3...0.3).contains(dx), (-0.1...0.4).contains(dy) else {
                message = "المسافة بين النقطتين خارج نطاق المعايرة. اختر الاسم والجسم لنفس اللاعب."
                return
            }
            AssistanceState.shared.configuration.colorOffsetX = dx
            AssistanceState.shared.configuration.colorOffsetY = dy
        }
        // The video session is suspended while this sheet is open.
        // Keep the user's choice; the engine will require L2/R2 release on resume.
        AIAnalysisState.shared.colorHue = hue
        AIAnalysisState.shared.colorMode = true
        guard AIAnalysisState.shared.saveSettings(),
              AssistanceState.shared.saveSettings() else {
            message = "تعذر حفظ المعايرة. حاول مرة أخرى."
            return
        }
        dismiss()
    }
}


// MARK: - Shared color helpers

extension UIColor {
    convenience init?(hexRGB text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6, let number = UInt32(normalized, radix: 16) else {
            return nil
        }
        self.init(red: CGFloat((number >> 16) & 0xFF) / 255,
                  green: CGFloat((number >> 8) & 0xFF) / 255,
                  blue: CGFloat(number & 0xFF) / 255,
                  alpha: 1)
    }

    var hueValue: Double {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Double(hue)
    }
}

// Apple Vision OCR and manual name/color capture removed. YOLO detects
// anonymous person boxes; no textual identity is required for automatic tracking.
struct PlayerNameCaptureView: View {
    let shot: CalibrationShot
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("YOLO — كشف تلقائي").font(.headline)
                Text("يكتشف البرنامج الأشخاص والعلامات الدافئة فوقهم من بث PS5 دون اختيار الأسماء أو الألوان يدوياً.")
                Text("YOLO لا يقرأ أسماء اللاعبين، ولا يضمن أن كل علامة دافئة تعني فريق الخصم.")
                    .font(.footnote).foregroundStyle(.orange)
                Button("إغلاق") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(20)
                .navigationTitle("الكشف التلقائي")
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

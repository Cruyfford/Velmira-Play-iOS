import SwiftUI

@MainActor
final class AssistanceState: ObservableObject {
    static let shared = AssistanceState()
    @Published var armed = false
    @Published var configuration: AssistanceConfiguration { didSet { save() } }
    @Published private(set) var target: CGPoint?
    @Published private(set) var status = "متوقف"
    private init() {
        if let data = UserDefaults.standard.data(forKey: "velmira.assistance.v1"),
           let value = try? JSONDecoder().decode(AssistanceConfiguration.self, from: data) {
            configuration = value
        } else { configuration = AssistanceConfiguration() }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: "velmira.assistance.v1")
        }
    }
    func report(target: CGPoint?, status: String) {
        if self.target != target { self.target = target }
        if self.status != status { self.status = status }
    }
    func emergencyStop() { armed = false; target = nil; status = "متوقف" }
}

struct AssistanceSettings: View {
    @ObservedObject private var model = AssistanceState.shared
    @ObservedObject private var vision = AIAnalysisState.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                VelmiraSection("التحكم الفعلي — تجريبي") {
                    Toggle("تفعيل المساعدة عند L2", isOn: $model.armed)
                    Text("بعد التفعيل اترك L2 وR2 أولًا، ثم اضغط L2. حرّك العصا بقوة لاستعادة أولوية التحكم اليدوي.")
                    Button("إيقاف جميع المساعدات", role: .destructive) { model.emergencyStop() }
                    Text(model.status)
                    Text("تعديلات مصدر لم تُختبر على PS5 بعد. كشف الأشخاص لا يميز العدو من الصديق. وضع اللون يعتمد على لون علامة الخصم الذي تختاره.").font(.footnote)
                }
                VelmiraSection("التتبّع") {
                    Toggle("تحريك التصويب نحو الهدف", isOn: $model.configuration.tracking)
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
                    Text("بدون الانتقال التلقائي: اترك L2 واضغطه مجددًا لاختيار هدف جديد. تُوقف الحركة عند تقادم الصورة؛ لا يستمر التصويب نحو موقع قديم.").font(.footnote)
                }
                VelmiraSection("موضع التصويب داخل الجسم") {
                    HStack {
                        Button("الرأس") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.1 }
                        Button("البطن") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.55 }
                        Button("الرجل") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.88 }
                    }.buttonStyle(.bordered)
                    BodyPointPicker(x: $model.configuration.pointX, y: $model.configuration.pointY)
                    Text("اسحب الدائرة لأي موضع. الرسم توضيحي؛ تحديد الرأس تقديري داخل إطار الشخص وليس كشفًا تشريحيًا.").font(.footnote)
                }
                VelmiraSection("إذا كان اللون فوق الرأس") {
                    valueSlider("الإزاحة الأفقية من الاسم", value: $model.configuration.colorOffsetX, range: -0.3...0.3)
                    valueSlider("الإزاحة أسفل الاسم", value: $model.configuration.colorOffsetY, range: -0.1...0.4)
                    Text("الإزاحة نسبة من حجم الصورة. تختلف حسب المسافة والتقريب؛ عايرها على البث. نقطة الاسم ونقطة التصويب مختلفتان.").font(.footnote)
                }
                VelmiraSection("السنايبر — مرة لكل ضغطة L2") {
                    Toggle("Quick Scope: تصويب ثم R2", isOn: $model.configuration.quickScope)
                    valueSlider("التأخير قبل الطلقة", value: $model.configuration.scopeDelay, range: 0.05...2)
                    valueSlider("مدة ضغط R2", value: $model.configuration.shotDuration, range: 0.03...0.3)
                    Toggle("Silent Shot: طلقة ثم تبديل السلاح", isOn: $model.configuration.silentShot)
                    valueSlider("تأخير تبديل السلاح", value: $model.configuration.switchDelay, range: 0.03...1)
                    Text("التبديل يضغط مثلث وفق ترتيب أزرار اللعبة الافتراضي. الاسم هنا يعني تسلسل أزرار فقط، ولا يضمن إخفاء صوت الطلقة. ترك L2 يلغي التسلسل. الماكرو لا ينتظر كشف هدف.").font(.footnote)
                }
                VelmiraSection("تعويض الارتداد — L2 مع R2") {
                    Toggle("تعويض ثابت قابل للمعايرة", isOn: $model.configuration.recoil)
                    valueSlider("أفقي", value: $model.configuration.recoilX, range: -0.3...0.3)
                    valueSlider("رأسي", value: $model.configuration.recoilY, range: -0.3...0.3)
                    Text("ليس تثبيتًا مضمونًا لكل سلاح. اضبطه لكل حساسية وسلاح داخل ساحة تدريب.").font(.footnote)
                }
                VelmiraSection {
                    Button("استعادة القيم الافتراضية", role: .destructive) {
                        model.emergencyStop(); model.configuration = AssistanceConfiguration()
                    }
                    Text("تُحفظ الإعدادات محليًا، لكن التشغيل يبدأ متوقفًا كل مرة.")
                }
            }
                .padding(20)
            }
            .background(TPPlayTheme.canvas)
            .navigationTitle("التحكم والمساعدة")
            .navigationBarTitleDisplayMode(.inline)
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
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.25))
                Image(systemName: "figure.stand")
                    .resizable().scaledToFit().foregroundStyle(.gray)
                    .padding(.vertical, 12).padding(.horizontal, 40)
                Text("ENEMY_01").font(.caption2).foregroundStyle(.red)
                    .position(x: geometry.size.width / 2, y: 12)
                Circle().stroke(Color.cyan, lineWidth: 3).frame(width: 20, height: 20)
                    .position(x: x * geometry.size.width, y: y * geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                x = min(1, max(0, value.location.x / geometry.size.width))
                y = min(1, max(0, value.location.y / geometry.size.height))
            })
        }.frame(height: 270).environment(\.layoutDirection, .leftToRight)
    }
}

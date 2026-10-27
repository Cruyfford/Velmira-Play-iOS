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
                VelmiraSection("لون العلامة فوق الرأس") {
                    Toggle("استخدام تتبّع اللون", isOn: $vision.colorMode)
                    HStack(spacing: 12) {
                        Button("أحمر") { vision.colorHue = 0 }
                        Button("أرجواني") { vision.colorHue = 0.88 }
                        Button("أصفر") { vision.colorHue = 0.16 }
                    }.buttonStyle(.bordered)
                    Text("درجة اللون")
                    LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 12).clipShape(Capsule())
                        .environment(\.layoutDirection, .leftToRight)
                    Slider(value: $vision.colorHue, in: 0...1)
                        .tint(Color(hue: vision.colorHue, saturation: 1, brightness: 1))
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityLabel("درجة لون العلامة")
                    Text("سماحية اختلاف اللون")
                    Slider(value: $vision.colorTolerance, in: 0.01...0.15)
                        .accessibilityLabel("سماحية اختلاف اللون")
                    Text("هذا نفس اختيار اللون في قسم الذكاء الاصطناعي. يتغير لون الاسم التوضيحي معه. يعتمد الكشف على درجة اللون وليس مطابقة درجة السطوع حرفياً.")
                        .font(.footnote)
                }
                VelmiraSection("موضع التصويب داخل الجسم") {
                    HStack {
                        Button("الرأس") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.1 }
                        Button("البطن") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.55 }
                        Button("الرجل") { model.configuration.pointX = 0.5; model.configuration.pointY = 0.88 }
                    }.buttonStyle(.bordered)
                    BodyPointPicker(x: $model.configuration.pointX, y: $model.configuration.pointY, hue: vision.colorHue)
                    Text("النقطة الملونة تمثل علامة الاسم. اسحب الدائرة السماوية لتحديد موضع الجسم في وضع كشف الأشخاص. في وضع اللون اضبط الإزاحة أسفل الاسم من القسم التالي؛ الرسم توضيحي وليس معايرة لمسافة الخصم.").font(.footnote)
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

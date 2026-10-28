import AuthenticationServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers


private struct VelmiraPortableAI: Codable {
    var colorMode: Bool
    var hybridMode: Bool
    var adaptiveBodyMarker: Bool
    var precisionMode: Bool
    var colorHue: Double
    var colorTolerance: Double
    var enabled: Bool
    var threshold: Double
    var rate: Double
}

private struct VelmiraPortableStream: Codable {
    var resolution: Int
    var fps: Int
    var bitrate: Int
}

private struct VelmiraPortableTouch: Codable {
    var presets: [TouchLayoutPreset]
    var activePresetID: UUID
}

/// Shareable user preferences only. No PSN credentials, connection host,
/// console pairing, Keychain values, account information, or private roster.
private struct VelmiraSettingsPackage: Codable {
    var format: String
    var version: Int
    var exportedAt: String
    var assistance: AssistanceConfiguration
    var ai: VelmiraPortableAI
    var stream: VelmiraPortableStream
    var touch: VelmiraPortableTouch
    var gameProfiles: [GameProfile]
    var showMetrics: Bool
    var autoScanEnabled: Bool
}

private enum VelmiraImportError: LocalizedError {
    case wrongFormat
    case unsupportedVersion
    case invalidValue(String)
    case tooLarge
    case cannotRead
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .wrongFormat: "الملف ليس ملف إعدادات Velmira Play صالحًا."
        case .unsupportedVersion: "إصدار ملف الإعدادات غير مدعوم في هذه النسخة."
        case .invalidValue(let field): "قيمة غير صالحة في الملف: \(field). لم يتم تغيير الإعدادات."
        case .tooLarge: "ملف الإعدادات أكبر من الحد المسموح (1 ميجابايت)."
        case .cannotRead: "تعذر قراءة ملف الإعدادات. اختر ملف JSON صادرًا من Velmira Play."
        case .cannotSave: "تعذر حفظ الإعدادات المستوردة."
        }
    }
}

private struct VelmiraSettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw VelmiraImportError.cannotRead
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
private enum VelmiraSettingsTransfer {
    static func exportCurrent() throws -> VelmiraSettingsDocument {
        let ai = AIAnalysisState.shared
        let defaults = UserDefaults.standard
        let touch = TouchLayoutStore.shared
        let package = VelmiraSettingsPackage(
            format: "velmira-play-settings",
            version: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            assistance: AssistanceState.shared.configuration,
            ai: VelmiraPortableAI(
                colorMode: ai.colorMode, hybridMode: ai.hybridMode,
                adaptiveBodyMarker: ai.adaptiveBodyMarker, precisionMode: ai.precisionMode,
                colorHue: ai.colorHue, colorTolerance: ai.colorTolerance,
                enabled: ai.enabled, threshold: ai.threshold, rate: ai.rate),
            stream: VelmiraPortableStream(
                resolution: defaults.object(forKey: "streamResolution") as? Int ?? 1080,
                fps: defaults.object(forKey: "streamFPS") as? Int ?? 60,
                bitrate: defaults.object(forKey: "streamBitrate") as? Int ?? 15_000),
            touch: VelmiraPortableTouch(
                presets: touch.presets, activePresetID: touch.activePresetID),
            gameProfiles: GameProfiles.shared.profiles,
            showMetrics: defaults.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false,
            autoScanEnabled: MatchRoster.shared.autoScanEnabled)
        try validate(package)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return VelmiraSettingsDocument(data: try encoder.encode(package))
    }

    static func importFile(at url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           bytes > 1_048_576 {
            throw VelmiraImportError.tooLarge
        }
        let resource = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard resource?.isRegularFile != false,
              let data = try? Data(contentsOf: url),
              data.count <= 1_048_576 else {
            throw VelmiraImportError.cannotRead
        }
        let decoder = JSONDecoder()
        guard let profile = try? decoder.decode(VelmiraSettingsPackage.self, from: data) else {
            throw VelmiraImportError.wrongFormat
        }
        try validate(profile)
        // Validate and encode everything *before* changing any saved preferences.
        let encoder = JSONEncoder()
        let touchData = try encoder.encode(profile.touch)
        let profilesData = try encoder.encode(profile.gameProfiles)

        let assistance = AssistanceState.shared
        let ai = AIAnalysisState.shared
        let defaults = UserDefaults.standard
        // Never arm controller motion from an imported document.
        assistance.emergencyStop(reason: "تم تحميل إعدادات جديدة؛ التفعيل يدوي")
        GameProfiles.shared.discardUnsavedProfile()
        assistance.configuration = profile.assistance
        ai.colorMode = profile.ai.colorMode
        ai.hybridMode = profile.ai.hybridMode
        ai.adaptiveBodyMarker = profile.ai.adaptiveBodyMarker
        ai.precisionMode = profile.ai.precisionMode
        ai.colorHue = profile.ai.colorHue
        ai.colorTolerance = profile.ai.colorTolerance
        ai.threshold = profile.ai.threshold
        ai.rate = profile.ai.rate
        ai.enabled = profile.ai.enabled
        guard assistance.saveSettings(), ai.saveSettings() else {
            throw VelmiraImportError.cannotSave
        }
        defaults.set(profile.stream.resolution, forKey: "streamResolution")
        defaults.set(profile.stream.fps, forKey: "streamFPS")
        defaults.set(profile.stream.bitrate, forKey: "streamBitrate")
        defaults.set(profile.showMetrics, forKey: "velmira.showMetrics.compact.v2")
        defaults.set(touchData, forKey: "tpplay.touchLayouts.v2")
        TouchLayoutStore.shared.restoreSavedLayouts()
        defaults.set(profilesData, forKey: "velmira.gameProfiles.v1")
        GameProfiles.shared.profiles = profile.gameProfiles
        MatchRoster.shared.autoScanEnabled = profile.autoScanEnabled
        MatchRoster.shared.saveAutoScanSetting()
    }

    private static func check(_ value: Double, _ range: ClosedRange<Double>,
                              _ name: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw VelmiraImportError.invalidValue(name)
        }
    }

    private static func checkAssistance(_ c: AssistanceConfiguration) throws {
        try check(c.radius, 0.05...0.5, "نطاق التتبع")
        try check(c.strength, 0.1...5, "قوة التصحيح")
        try check(c.maxStick, 0.02...0.8, "حد حركة العصا")
        try check(c.deadZone, 0...0.2, "المنطقة الميتة")
        try check(c.response, 0.02...0.5, "تنعيم التتبع")
        try check(c.manualOverride, 0.1...1, "أولوية التحكم اليدوي")
        try check(c.staleAfter, 0.1...0.8, "صلاحية إطار الفيديو")
        try check(c.lossDelay, 0.15...2, "مهلة فقد الهدف")
        try check(c.pointX, 0...1, "موضع الجسم X")
        try check(c.pointY, 0...1, "موضع الجسم Y")
        try check(c.colorOffsetX, -0.3...0.3, "إزاحة اللون X")
        try check(c.colorOffsetY, -0.1...0.4, "إزاحة اللون Y")
        try check(c.scopeDelay, 0.05...2, "تأخير السنايبر")
        try check(c.shotDuration, 0.03...0.3, "مدة الطلقة")
        try check(c.switchDelay, 0.03...1, "تأخير تبديل السلاح")
        try check(c.switchDuration, 0.03...0.3, "مدة تبديل السلاح")
        try check(c.recoilX, -0.3...0.3, "الارتداد X")
        try check(c.recoilY, -0.3...0.3, "الارتداد Y")
    }

    private static func validate(_ p: VelmiraSettingsPackage) throws {
        guard p.format == "velmira-play-settings" else {
            throw VelmiraImportError.wrongFormat
        }
        guard p.version == 1 else {
            throw VelmiraImportError.unsupportedVersion
        }
        try checkAssistance(p.assistance)
        try check(p.ai.colorHue, 0...1, "لون العلامة")
        try check(p.ai.colorTolerance, 0.01...0.15, "سماحية اللون")
        try check(p.ai.threshold, 0.2...0.95, "ثقة الذكاء الاصطناعي")
        guard [3.0, 5.0, 8.0].contains(p.ai.rate) else {
            throw VelmiraImportError.invalidValue("معدل التحليل")
        }
        guard [720, 1080].contains(p.stream.resolution),
              [30, 60].contains(p.stream.fps),
              (2_000...100_000).contains(p.stream.bitrate) else {
            throw VelmiraImportError.invalidValue("جودة البث")
        }
        let presets = p.touch.presets
        guard (1...40).contains(presets.count),
              Set(presets.map(\.id)).count == presets.count,
              presets.contains(where: { $0.id == p.touch.activePresetID }) else {
            throw VelmiraImportError.invalidValue("تخطيطات أزرار اللمس")
        }
        for preset in presets {
            guard !preset.name.isEmpty, preset.name.count <= 64,
                  preset.layout.centers.count <= 80, preset.layout.scales.count <= 80,
                  (preset.layout.touchpadActions?.count ?? 0) <= 4 else {
                throw VelmiraImportError.invalidValue("تخطيط الأزرار")
            }
            for point in preset.layout.centers.values {
                try check(point.x, 0...1, "موضع زر X")
                try check(point.y, 0...1, "موضع زر Y")
            }
            for size in preset.layout.scales.values {
                try check(size, 0.55...1.7, "حجم زر اللمس")
            }
            if let left = preset.layout.leftStickSensitivity {
                try check(left, 0.5...3, "حساسية العصا اليسرى")
            }
            if let right = preset.layout.rightStickSensitivity {
                try check(right, 0.5...3, "حساسية العصا اليمنى")
            }
        }
        guard p.gameProfiles.count <= 40,
              Set(p.gameProfiles.map(\.id)).count == p.gameProfiles.count else {
            throw VelmiraImportError.invalidValue("ملفات الألعاب")
        }
        for game in p.gameProfiles {
            guard !game.name.isEmpty, game.name.count <= 80,
                  [720, 1080].contains(game.resolution),
                  [30, 60].contains(game.fps),
                  (2_000...100_000).contains(game.bitrate),
                  [3.0, 5.0, 8.0].contains(game.rate) else {
                throw VelmiraImportError.invalidValue("ملف إعدادات اللعبة")
            }
            try checkAssistance(game.assistance)
            try check(game.hue, 0...1, "لون ملف اللعبة")
            try check(game.tolerance, 0.01...0.15, "سماحية ملف اللعبة")
            try check(game.threshold, 0.2...0.95, "ثقة ملف اللعبة")
        }
    }
}

struct HomeView: View {
    @State private var showImportPicker = false
    @State private var showExportPicker = false
    @State private var exportDocument: VelmiraSettingsDocument?
    @State private var settingsTransferNotice = ""
    @State private var settingsTransferFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TPPageHeader("الإعدادات")
                    NavigationLink {
                        AssistanceSettings()
                    } label: { settingsCard("يد التحكم", subtitle: "تخصيص L2 وR2 والمساعدة", icon: "gamecontroller") }
                    NavigationLink {
                        VelmiraAdvancedSettings()
                    } label: { settingsCard("جودة الفيديو والحساب", subtitle: "الدقة والإطارات وربط PlayStation", icon: "tv") }
                    NavigationLink {
                        TouchLayoutSettingsView()
                    } label: { settingsCard("أزرار اللمس", subtitle: "ترتيب أدوات التحكم على الشاشة", icon: "hand.tap") }
                    NavigationLink {
                        LinkDiagnosticView()
                    } label: { settingsCard("فحص الاتصال", subtitle: "اختبار اتصالك بجهاز PS5", icon: "wifi") }
                    NavigationLink {
                        RemotePlayInternetSettingsView()
                    } label: {
                        settingsCard("الاتصال البعيد عبر 5G", subtitle: "تسجيل PSN وربط جهاز PS5 عبر الإنترنت", icon: "globe")
                    }
                    VelmiraSection("مشاركة وتحميل الإعدادات") {
                        Text("استورد جميع إعدادات التطبيق من ملف JSON، أو صدّر إعداداتك وأرسلها إلى شخص آخر. الاستيراد يحفظها مباشرة بعد التحقق من الملف.")
                            .font(.footnote)
                        Button {
                            showImportPicker = true
                        } label: {
                            Label("لود الإعدادات — اختيار ملف من الجهاز", systemImage: "square.and.arrow.down.on.square")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(AcidButtonStyle(active: true))
                        Button {
                            do {
                                exportDocument = try VelmiraSettingsTransfer.exportCurrent()
                                settingsTransferNotice = ""
                                showExportPicker = true
                            } catch {
                                settingsTransferFailed = true
                                settingsTransferNotice = error.localizedDescription
                            }
                        } label: {
                            Label("تصدير الإعدادات — ملف للمشاركة", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(AcidButtonStyle())
                        Text("الصيغة: Velmira-Settings.json — يشمل التحكم والذكاء الاصطناعي وموضع الجسم والبث واللمس وملفات الألعاب. لا يشمل حساب PSN أو بيانات اتصال الأجهزة.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !settingsTransferNotice.isEmpty {
                            Text(settingsTransferNotice)
                                .font(.footnote)
                                .foregroundStyle(settingsTransferFailed ? Color.orange : Color.green)
                        }
                    }
                    VelmiraSection {
                        HStack {
                            Image(systemName: "lock.shield").foregroundStyle(TPPlayTheme.accent)
                            Text("معالجة الصورة على جهازك").font(.headline)
                        }
                        Text("VELMIRA PLAY").font(.caption).tracking(2)
                    }
                }.padding(20)
            }
            .background(TPPlayTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            // Files / iCloud / ChatGPT downloads may identify a .json file as
            // generic data rather than public.json. Allow picking any file here;
            // importFile performs size, JSON schema and numeric-range validation
            // before it applies or saves user preferences.
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    do {
                        try VelmiraSettingsTransfer.importFile(at: url)
                        settingsTransferFailed = false
                        settingsTransferNotice = "تم تحميل الإعدادات وحفظها بنجاح. التفعيل اليدوي للمساعدة يبقى متوقفًا."
                    } catch {
                        settingsTransferFailed = true
                        settingsTransferNotice = error.localizedDescription
                    }
                case .failure(let error):
                    settingsTransferFailed = true
                    settingsTransferNotice = error.localizedDescription
                }
            }
            .fileExporter(isPresented: $showExportPicker, document: exportDocument,
                          contentType: .json, defaultFilename: "Velmira-Settings") { result in
                switch result {
                case .success:
                    settingsTransferFailed = false
                    settingsTransferNotice = "تم تصدير ملف الإعدادات. يمكنك مشاركته عبر تطبيق الملفات."
                case .failure(let error):
                    settingsTransferFailed = true
                    settingsTransferNotice = error.localizedDescription
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
    private func settingsCard(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 28, weight: .regular))
                .foregroundStyle(TPPlayTheme.accent).frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(TPPlayTheme.primaryText)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(TPPlayTheme.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(TPPlayTheme.secondaryText)
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(LinearGradient(colors: [TPPlayTheme.surfaceRaised, TPPlayTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(TPPlayTheme.border.opacity(0.7), lineWidth: 1) }
    }
}

struct VelmiraAdvancedSettings: View {
    @StateObject private var psnLibrary = PSNLibraryStore.shared
    @StateObject private var psnAuthenticator = PSNWebAuthenticator()
    @ObservedObject private var touchLayouts = TouchLayoutStore.shared
    @State private var resolution = 1080
    @State private var fps = 60
    @State private var bitrate = 15_000
    @State private var saveNotice = ""
    @State private var showingTouchLayouts = false
    @State private var showingLinkDiagnostic = false

    var body: some View {
        VStack(spacing: 0) {
            TPPageHeader("الحساب وجودة البث")
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .background(TPPlayTheme.canvas)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                psnAccountPanel
                touchControlsPanel
                Button("فحص الاتصال") { showingLinkDiagnostic = true }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(AcidButtonStyle())
                VStack(alignment: .leading, spacing: 18) {
                    configHeader("جودة الفيديو", value: "\(resolution)P / \(fps)FPS")
                    choiceRow("الدقة", choices: [("720P", 720), ("1080P", 1080)], selection: $resolution)
                    choiceRow("معدل الإطارات", choices: [("30 FPS", 30), ("60 FPS", 60)], selection: $fps)
                    VStack(alignment: .leading, spacing: 8) {
                        configHeader("معدل البيانات", value: "\(bitrate / 1_000) MBPS // NEXT SESSION")
                        HStack(spacing: 8) {
                            Button("−") { bitrate = max(2_000, bitrate - 1_000) }
                                .frame(width: 48, height: 44)
                                .buttonStyle(AcidButtonStyle())
                            Text("\(bitrate / 1_000)")
                                .font(.system(size: 18, weight: .black, design: .default))
                                .foregroundStyle(TPPlayTheme.accent)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(TPPlayTheme.canvas)
                                .overlay { RoundedRectangle(cornerRadius: 20).stroke(TPPlayTheme.border, lineWidth: 1) }
                            Button("+") { bitrate = min(100_000, bitrate + 1_000) }
                                .frame(width: 48, height: 44)
                                .buttonStyle(AcidButtonStyle())
                        }
                        Text("رفع معدل البيانات يحسّن الصورة ويتطلب اتصالاً مستقراً.")
                            .font(.system(size: 8, weight: .bold, design: .default))
                            .tracking(0.35)
                            .foregroundStyle(TPPlayTheme.tertiaryText)
                    }
                    Button("استعادة القيم الموصى بها") {
                        resolution = 1080
                        fps = 60
                        bitrate = 15_000
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(AcidButtonStyle())
                    Button {
                        UserDefaults.standard.set(resolution, forKey: "streamResolution")
                        UserDefaults.standard.set(fps, forKey: "streamFPS")
                        UserDefaults.standard.set(bitrate, forKey: "streamBitrate")
                        saveNotice = "تم حفظ جودة البث، وستستخدم في الاتصال التالي."
                    } label: {
                        Label("حفظ إعدادات جودة البث", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))
                    Text(saveNotice.isEmpty ? "التغييرات مؤقتة حتى تضغط حفظ الإعدادات." : saveNotice)
                        .font(.footnote)
                }
                .padding(16)
                .background(TPPlayTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(TPPlayTheme.border, lineWidth: 1) }

                VStack(alignment: .leading, spacing: 8) {
                    Text("VELMIRA PLAY")
                        .font(.system(size: 14, weight: .black, design: .default))
                        .foregroundStyle(TPPlayTheme.primaryText)
                    Text("اللعب عن بُعد في تطبيق واحد")
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .tracking(0.8)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(TPPlayTheme.violet, lineWidth: 1) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        .background(TPPlayTheme.canvas)
        .onAppear { loadStreamSettings() }
        .onDisappear { loadStreamSettings() }
        .fullScreenCover(isPresented: $showingTouchLayouts) {
            TouchLayoutSettingsView()
        }
        .fullScreenCover(isPresented: $showingLinkDiagnostic) {
            LinkDiagnosticView()
        }
    }

    private func loadStreamSettings() {
        let defaults = UserDefaults.standard
        resolution = defaults.object(forKey: "streamResolution") as? Int ?? 1080
        fps = defaults.object(forKey: "streamFPS") as? Int ?? 60
        bitrate = defaults.object(forKey: "streamBitrate") as? Int ?? 15_000
        saveNotice = ""
    }

    private var touchControlsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            configHeader("أزرار اللمس", value: "\(touchLayouts.presets.count) PRESET\(touchLayouts.presets.count == 1 ? "" : "S")")
            HStack(spacing: 12) {
                Rectangle()
                    .fill(TPPlayTheme.violet)
                    .frame(width: 8, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("تخطيطات التحكم")
                        .font(.system(size: 14, weight: .black, design: .default))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    Text("اختر تخطيط الأزرار أثناء اللعب")
                        .font(.system(size: 8, weight: .bold, design: .default))
                        .tracking(0.6)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                Spacer()
            }
            Button("تخصيص أزرار الشاشة") { showingTouchLayouts = true }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
        }
        .padding(16)
        .background(TPPlayTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private var psnAccountPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            configHeader("PLAYSTATION NETWORK", value: psnLibrary.signedInOnlineID?.uppercased() ?? "غير متصل")

            if psnLibrary.isSignedIn {
                Text("تم ربط حساب PlayStation")
                    .font(.system(size: 9, weight: .black, design: .default))
                    .foregroundStyle(TPPlayTheme.accent)
                Button(psnLibrary.isLoading ? "جارٍ المزامنة…" : "مزامنة المكتبة") {
                    Task { await psnLibrary.sync() }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
                .disabled(psnLibrary.isLoading)
                Button("تسجيل الخروج") { psnLibrary.signOut() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(AcidButtonStyle())
            } else {
                Button(psnLibrary.isLoading || psnAuthenticator.isAuthenticating ? "جارٍ الاتصال…" : "ربط حساب PlayStation") {
                    Task { await psnAuthenticator.connect(library: psnLibrary) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
                .disabled(psnLibrary.isLoading || psnAuthenticator.isAuthenticating)
                Text("يتم تسجيل الدخول عبر صفحة Sony الآمنة، وتُحفظ بيانات الجلسة في سلسلة مفاتيح iOS.")
                    .font(.system(size: 8, weight: .medium, design: .default))
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }

            if let error = psnLibrary.errorMessage ?? psnAuthenticator.errorMessage {
                Text("ERROR // \(error.uppercased())")
                    .font(.system(size: 9, weight: .black, design: .default))
                    .foregroundStyle(TPPlayTheme.danger)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { RoundedRectangle(cornerRadius: 20).stroke(TPPlayTheme.danger, lineWidth: 1) }
            }
        }
        .padding(16)
        .background(TPPlayTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private func configHeader(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(TPPlayTheme.secondaryText)
            Spacer()
            Text(value).foregroundStyle(TPPlayTheme.accent)
        }
        .font(.system(size: 10, weight: .bold, design: .default))
        .tracking(0.6)
    }

    private func choiceRow(_ title: String, choices: [(String, Int)], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .default))
                .foregroundStyle(TPPlayTheme.secondaryText)
            HStack(spacing: 8) {
                ForEach(choices, id: \.1) { choice in
                    Button(choice.0) { selection.wrappedValue = choice.1 }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle(active: selection.wrappedValue == choice.1))
                }
            }
        }
    }
}

@MainActor
private final class PSNWebAuthenticator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private var session: ASWebAuthenticationSession?
    private weak var presentationWindow: UIWindow?

    func connect(library: PSNLibraryStore) async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            let callback = try await authenticate()
            await library.signIn(from: callback.absoluteString)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate() async throws -> URL {
        guard session == nil else { throw PSNWebAuthenticationError.alreadyRunning }
        guard let window = Self.activeWindow else { throw PSNWebAuthenticationError.noPresentationWindow }
        presentationWindow = window

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: PSNLibraryStore.loginURL,
                callbackURLScheme: PSNLibraryStore.loginCallbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.session = nil
                    self?.presentationWindow = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: PSNWebAuthenticationError.missingCallback)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                self.session = nil
                self.presentationWindow = nil
                continuation.resume(throwing: PSNWebAuthenticationError.couldNotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? Self.activeWindow ?? UIWindow()
    }

    private static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private enum PSNWebAuthenticationError: LocalizedError {
    case alreadyRunning
    case noPresentationWindow
    case missingCallback
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A PSN sign-in is already running."
        case .noPresentationWindow: "TP Play could not present the PSN sign-in window."
        case .missingCallback: "Sony completed sign-in without returning an authorization code."
        case .couldNotStart: "TP Play could not start the PSN sign-in session."
        }
    }
}

#Preview { HomeView() }


/// Sets up the existing Chiaki PSN holepunch route without exposing secrets in logs.
/// Tokens are persisted solely in Keychain; one-use OAuth redirects never leave this UI.
struct RemotePlayInternetSettingsView: View {
    @ObservedObject private var remote = RemoteCredentialStore.shared
    @StateObject private var registered = RegisteredConsoleStore()
    @State private var pastedRedirect = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VelmiraSection("اتصال PS5 عبر 5G والإنترنت") {
                    Text("ربط الحساب هنا مختلف عن مزامنة الكؤوس. هذا الربط يتيح اختيار جهازك من قائمة PlayStation Network.")
                    Text(remote.isSignedIn ? "حساب الاتصال البعيد: \(remote.accountName ?? "PSN")" : "لم يتم ربط حساب الاتصال البعيد.")
                        .foregroundStyle(remote.isSignedIn ? .green : .orange)
                    Button("1 — فتح تسجيل دخول Sony للاتصال البعيد") {
                        if let url = remote.authorizationURL() {
                            UIApplication.shared.open(url)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(AcidButtonStyle(active: true))
                    Text("بعد تسجيل الدخول في Safari، انسخ الرابط النهائي من شريط العنوان والصقه في الحقل الآمن هنا. لا ترسل الرابط أو رمزه لأي شخص.")
                        .font(.footnote)
                    SecureField("2 — الصق رابط Sony النهائي هنا", text: $pastedRedirect)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AcidFieldStyle())
                        .environment(\.layoutDirection, .leftToRight)
                    Button(remote.isLinking ? "جارٍ ربط PSN…" : "3 — حفظ الربط واكتشاف أجهزة PS5") {
                        let submitted = pastedRedirect
                        pastedRedirect = ""
                        Task { _ = await remote.linkFromPSNRedirect(submitted) }
                    }
                    .disabled(pastedRedirect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remote.isLinking)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(AcidButtonStyle(active: true))
                    if remote.isLinking { ProgressView() }
                    if let status = remote.statusMessage {
                        Text(status).font(.footnote)
                    }
                    if let error = remote.storageError {
                        Text("تعذر فتح بيانات الاتصال الآمنة: \(error)")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                VelmiraSection("أجهزة PlayStation المتاحة عبر الإنترنت") {
                    Button(remote.isRefreshingDevices ? "جارٍ تحديث الأجهزة…" : "تحديث أجهزة PS5 من PSN") {
                        Task { await remote.updateRemoteDevices() }
                    }
                    .disabled(!remote.isSignedIn || remote.isRefreshingDevices)
                    if remote.isRefreshingDevices { ProgressView() }
                    if remote.linkedDevices.isEmpty {
                        Text("لا توجد أجهزة قابلة للاتصال بعد. فعّل Remote Play على PS5، وتأكد من حساب Sony نفسه، ثم حدث القائمة.")
                            .font(.footnote)
                    } else {
                        ForEach(remote.linkedDevices, id: \.self) { name in
                            Label(name, systemImage: "gamecontroller.fill")
                        }
                    }
                }
                ForEach(registered.consoles) { console in
                    RemoteConsoleSelectionRow(console: console, remote: remote)
                }
                VelmiraSection("خطوات التشغيل") {
                    Text("على PS5: الإعدادات ← النظام ← اللعب عن بُعد ← تمكين اللعب عن بُعد. وللتشغيل من وضع السكون فعّل البقاء متصلاً بالإنترنت والسماح بالتشغيل عبر الشبكة.")
                    Text("بعد ربط الحساب والجهاز، افتح قسم PS5 واضغط «بدء اللعب» ثم اختر تلقائي أو الإنترنت. يعمل عبر Wi-Fi أو بيانات الهاتف متى سمحت الشبكة وPSN بذلك.")
                    Text("قد تمنع بعض شبكات 5G وNAT الاتصال حتى بعد نجاح الربط؛ نجاح التسجيل لا يضمن اكتمال الاتصال أو سرعة ثابتة.")
                        .font(.footnote)
                    Button("فصل حساب الاتصال البعيد", role: .destructive) {
                        remote.unlink()
                    }
                    .disabled(!remote.isSignedIn)
                }
            }
            .padding(20)
        }
        .background(TPPlayTheme.canvas)
        .navigationTitle("الاتصال عن بُعد")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct RemoteConsoleSelectionRow: View {
    let console: RegisteredConsole
    @ObservedObject var remote: RemoteCredentialStore

    var body: some View {
        VelmiraSection("ربط \(console.nickname) بجهاز PSN") {
            if remote.linkedDevices.isEmpty {
                Text("افتح تسجيل الدخول أولًا ثم حدث أجهزة PSN.").font(.footnote)
            } else {
                Text("اختر اسم الجهاز الصحيح؛ يُستخدم في الاتصال عن بُعد فقط.")
                    .font(.footnote)
                ForEach(remote.linkedDevices, id: \.self) { name in
                    Button {
                        remote.selectRemoteDevice(name, for: console)
                    } label: {
                        HStack {
                            Image(systemName: remote.selectedDeviceName(for: console) == name
                                  ? "checkmark.circle.fill" : "circle")
                            Text(name)
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

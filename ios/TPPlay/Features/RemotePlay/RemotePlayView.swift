import SwiftUI
import GameController
import UIKit

struct RemotePlayView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var session: RemotePlaySession
    @ObservedObject private var touchLayouts = TouchLayoutStore.shared
    @ObservedObject private var aiAnalysis = AIAnalysisState.shared
    @ObservedObject private var assistance = AssistanceState.shared
    @ObservedObject private var weaponStore = MW3WeaponStore.shared
    @ObservedObject private var roster = MatchRoster.shared
    @State private var showingWeaponLibrary = false
    @State private var showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
    @State private var savedStreamNotice = ""
    @State private var calibrationShot: CalibrationShot?
    @State private var playerNameShot: CalibrationShot?
    @State private var showingRoster = false
    @State private var showingStreamSettings = false
    @State private var showingQuickSettings = false
    @State private var pendingStreamCalibration = false
    @State private var pendingScoreboardScan = false
    @State private var calibrationError = false
    @State private var loginPIN = ""
    @State private var hasExternalController = false
    @State private var showsVirtualControls = true
    @State private var isClosing = false
    @State private var isEditingTouchLayout = false
    @State private var isChoosingTouchLayout = false
    @State private var showsSessionMenu = false
    @State private var showsExitConfirmation = false
    @State private var showsNewPresetDialog = false
    @State private var touchLayoutResetToken = 0
    @State private var wasBackgrounded = false

    init(session: RemotePlaySession) {
        self.session = session
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalVideoView(renderer: session.renderer)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard hasExternalController else { return }
                    guard !isEditingTouchLayout, !isChoosingTouchLayout,
                          !showsExitConfirmation, !showsNewPresetDialog else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsVirtualControls.toggle()
                        if !showsVirtualControls { showsSessionMenu = false }
                    }
                }

            AIAnalysisOverlay().ignoresSafeArea()

            controls
            streamToolbar
            if showingQuickSettings && !isEditingTouchLayout && !isChoosingTouchLayout {
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .top) {
                        Spacer(minLength: 0)
                        InStreamQuickControls(session: session,
                            onFullSettings: {
                                showingQuickSettings = false
                                openStreamSettings()
                            }, onClose: { showingQuickSettings = false })
                            .frame(maxWidth: 370)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.top, 68)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .zIndex(15)
            }

            if showsExitConfirmation {
                Color.black.opacity(0.74)
                    .ignoresSafeArea()
                    .zIndex(20)
                StreamExitDialog(
                    onExit: closeSession,
                    onCancel: { showsExitConfirmation = false }
                )
                .frame(maxWidth: 390)
                .padding(20)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(21)
            }

            if showsNewPresetDialog {
                Color.black.opacity(0.74)
                    .ignoresSafeArea()
                    .zIndex(22)
                StreamPresetNameDialog(
                    onCreate: createPreset,
                    onCancel: { showsNewPresetDialog = false }
                )
                .frame(maxWidth: 390)
                .padding(20)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(23)
            }

            if case .connecting(let stage) = session.state {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(TPPlayTheme.accent)
                    Text(stage.label)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(TPPlayTheme.primaryText)
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(TPPlayTheme.surface.opacity(0.92))
                .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
            }

            if case .ended(let reason) = session.state {
                VStack(spacing: 18) {
                    ContentUnavailableView("Remote Play ended", systemImage: "rectangle.slash", description: Text(reason))
                        .foregroundStyle(.white)
                    Button {
                        closeSession()
                    } label: {
                        Label("العودة إلى صفحة الأجهزة", systemImage: "arrow.uturn.backward")
                            .font(.headline.bold())
                            .frame(minWidth: 220, minHeight: 52)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))
                    .accessibilityLabel("العودة إلى صفحة الأجهزة بعد انتهاء البث")
                }
                .padding(.horizontal, 20)
                .zIndex(11)
            }

            if isClosing {
                HStack(spacing: 12) {
                    ProgressView().tint(TPPlayTheme.accent)
                    Text("CLOSING SESSION")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(TPPlayTheme.surface.opacity(0.94))
                .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
                .zIndex(10)
            }
        }
        .sheet(isPresented: $showingStreamSettings, onDismiss: {
            // A one-shot scoreboard photo or calibration starts only *after*
            // the settings sheet is fully closed. Neither needs a separate
            // stream or a new PSN pairing.
            if pendingStreamCalibration {
                pendingStreamCalibration = false
                openCalibrationCapture()
            } else if pendingScoreboardScan {
                pendingScoreboardScan = false
                captureScoreboard()
            } else if scenePhase == .active {
                session.resumeAssistance()
            }
            showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
        }) {
            InStreamSettingsCenter(
                session: session,
                showMetrics: $showMetrics,
                onClose: { showingStreamSettings = false },
                onCalibrate: {
                    pendingStreamCalibration = true
                    showingStreamSettings = false
                },
                onScanTeams: {
                    pendingScoreboardScan = true
                    showingStreamSettings = false
                }
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingWeaponLibrary, onDismiss: {
            if scenePhase == .active { session.resumeAssistance() }
        }) {
            NavigationStack {
                MW3WeaponCatalogView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("إغلاق") { showingWeaponLibrary = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingRoster, onDismiss: {
            if scenePhase == .active { session.resumeAssistance() }
        }) {
            NavigationStack {
                MatchRosterView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("إغلاق") { showingRoster = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $calibrationShot, onDismiss: {
            if scenePhase == .active { session.resumeAssistance() }
        }) { shot in
            StreamCalibrationView(shot: shot).preferredColorScheme(.dark)
        }
        .sheet(item: $playerNameShot, onDismiss: {
            if scenePhase == .active { session.resumeAssistance() }
        }) { shot in
            PlayerNameCaptureView(shot: shot).preferredColorScheme(.dark)
        }
        .alert("لا توجد لقطة حديثة", isPresented: $calibrationError) {
            Button("حسناً", role: .cancel) {}
        } message: { Text("انتظر ظهور بث PS5 ثم افتح المعايرة مجدداً.") }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .interactiveDismissDisabled()
        .alert("Console login PIN", isPresented: loginPINBinding) {
            SecureField("PIN", text: $loginPIN)
                .keyboardType(.numberPad)
            Button("Submit") {
                session.submitLoginPIN(loginPIN)
                loginPIN = ""
            }
            Button("Stop", role: .cancel) { session.stop() }
        } message: {
            if case .loginPINRequired(let incorrect) = session.state {
                Text(incorrect ? "That PIN was incorrect. Try again." : "Enter the user login PIN configured on the console.")
            }
        }
        .onAppear {
            TPPlayOrientation.set(.landscape)
            showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
            AIFrameAnalyzer.shared.setPaused(false)
            session.resumeAssistance()
            let controllers = GCController.controllers()
            controllers.forEach(session.attach)
            updateControllerPresence(controllers)
            GCController.startWirelessControllerDiscovery()
            UIApplication.shared.isIdleTimerDisabled = true
            VelmiraLiveDiagnostics.shared.record("STREAM", "بدأ عرض البث")
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { notification in
            if let controller = notification.object as? GCController {
                session.attach(controller)
                updateControllerPresence(GCController.controllers())
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { notification in
            if let controller = notification.object as? GCController {
                session.detach(controller)
            }
            updateControllerPresence(GCController.controllers())
        }
        .onDisappear {
            VelmiraLiveDiagnostics.shared.record("STREAM", "تم إغلاق شاشة البث")
            TPPlayOrientation.set(.portrait)
            AssistanceState.shared.restoreSavedSettings()
            AIAnalysisState.shared.restoreSavedSettings()
            touchLayouts.restoreSavedLayouts()
            GCController.stopWirelessControllerDiscovery()
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
        .onChange(of: session.state) { _, state in
            switch state {
            case .connecting: VelmiraLiveDiagnostics.shared.record("STREAM", "جارٍ الاتصال بجهاز PS5")
            case .connected: VelmiraLiveDiagnostics.shared.record("STREAM", "الاتصال بجهاز PS5 ناجح")
            case .loginPINRequired: VelmiraLiveDiagnostics.shared.record("STREAM", "مطلوب رمز دخول الجهاز")
            case .ended: VelmiraLiveDiagnostics.shared.record("STREAM", "انتهى اتصال PS5")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                TPPlayOrientation.set(.landscape)
                AIFrameAnalyzer.shared.setPaused(false)
                if calibrationShot == nil && playerNameShot == nil && !showingRoster && !showingStreamSettings { session.resumeAssistance() }
                UIApplication.shared.isIdleTimerDisabled = true
                if wasBackgrounded {
                    wasBackgrounded = false
                    session.requestVideoRefresh()
                }
            } else if phase == .background {
                session.suspendAssistance(reason: "انتقل التطبيق إلى الخلفية")
                AIFrameAnalyzer.shared.setPaused(true)
                AIAnalysisState.shared.clear()
                UIApplication.shared.isIdleTimerDisabled = false
                wasBackgrounded = true
            }
        }
    }


    // A narrow always-accessible bar replaces the wide row that used to
    // overlap the PS5 touchpad and shoulder controls in landscape mode.
    private var streamToolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: exitFromStream) {
                    Label("خروج", systemImage: "arrow.uturn.backward")
                        .padding(.horizontal, 13)
                        .frame(minHeight: 42)
                        .background(TPPlayTheme.danger.opacity(0.84), in: Capsule())
                }
                .accessibilityLabel("الخروج من البث والعودة إلى الأجهزة")

                Menu {
                    Button("جميع إعدادات البرنامج", systemImage: "gearshape.2.fill") {
                        openStreamSettings()
                    }
                    Button("معايرة لون وموضع الهدف", systemImage: "scope") {
                        openCalibrationCapture()
                    }
                    Button("قراءة الفريقين من لوحة النتائج", systemImage: "person.2.text") {
                        captureScoreboard()
                    }
                    Button("تشغيل YOLO والتصنيف التلقائي", systemImage: "viewfinder") {
                        aiAnalysis.prepareHybridTracking()
                    }
                    Button(showMetrics ? "إخفاء الأداء" : "عرض الأداء", systemImage: "chart.bar.xaxis") {
                        showMetrics.toggle()
                    }
                    Button(aiAnalysis.enabled ? "إيقاف تحليل الصورة" : "تشغيل تحليل الصورة",
                           systemImage: "viewfinder") {
                        aiAnalysis.enabled.toggle()
                    }
                    Button("زر PlayStation", systemImage: "gamecontroller.fill") {
                        session.clickPSButton()
                    }
                    Button("ترتيب أزرار اللمس", systemImage: "hand.draw") {
                        showsVirtualControls = true
                        isChoosingTouchLayout = true
                    }
                    Button("حفظ إعدادات البث", systemImage: "square.and.arrow.down") {
                        let a = AssistanceState.shared.saveSettings()
                        let b = AIAnalysisState.shared.saveSettings()
                        let c = touchLayouts.saveLayouts()
                        if a && b && c {
                            UserDefaults.standard.set(showMetrics, forKey: "velmira.showMetrics.compact.v2")
                            savedStreamNotice = "تم حفظ إعدادات البث."
                        } else {
                            savedStreamNotice = "تعذر حفظ بعض الإعدادات."
                        }
                    }
                    Button("استعادة إعدادات البث", systemImage: "arrow.counterclockwise") {
                        AssistanceState.shared.restoreSavedSettings()
                        AIAnalysisState.shared.restoreSavedSettings()
                        touchLayouts.restoreSavedLayouts()
                        showMetrics = UserDefaults.standard.object(forKey: "velmira.showMetrics.compact.v2") as? Bool ?? false
                        savedStreamNotice = "تم استعادة آخر إعدادات محفوظة."
                    }
                } label: {
                    Label("الأدوات", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 13)
                        .frame(minHeight: 42)
                        .background(.black.opacity(0.66), in: Capsule())
                        .overlay(Capsule().stroke(TPPlayTheme.accent.opacity(0.45), lineWidth: 1))
                }
                .accessibilityLabel("أدوات البث والإعدادات")

                Button {
                    withAnimation(.easeInOut(duration: 0.17)) { showingQuickSettings.toggle() }
                } label: {
                    Label("سريع", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 11)
                        .frame(minHeight: 42)
                        .background(TPPlayTheme.accent.opacity(0.8), in: Capsule())
                }
                .accessibilityLabel("إظهار لوحة إعدادات البث السريعة")
                Button {
                    openStreamSettings()
                } label: {
                    Label("الإعدادات", systemImage: "gearshape.2")
                        .padding(.horizontal, 12)
                        .frame(minHeight: 42)
                        .background(TPPlayTheme.violet.opacity(0.80), in: Capsule())
                }
                .accessibilityLabel("فتح جميع إعدادات Velmira Play أثناء بث PS5")

                Button {
                    captureScoreboard()
                } label: {
                    Label(roster.reading ? "قراءة..." : "قراءة الفريقين",
                          systemImage: "person.2.text")
                        .padding(.horizontal, 11)
                        .frame(minHeight: 42)
                        .background(.cyan.opacity(0.75), in: Capsule())
                }
                .disabled(roster.reading)
                .accessibilityLabel("قراءة أسماء الفريقين تلقائياً من لوحة نتائج MW3")

                Menu {
                    ForEach(0..<6, id: \.self) { index in
                        if let gun = weaponStore.weapon(in: index) {
                            Button {
                                let success = weaponStore.apply(gun)
                                savedStreamNotice = weaponStore.lastMessage
                                if !success {
                                    session.stopAssistanceNow()
                                }
                            } label: {
                                Label("\(index + 1) — \(gun.name)",
                                      systemImage: weaponStore.selectedID == gun.id
                                      ? "checkmark.circle.fill" : "circle")
                            }
                        } else {
                            Button("\(index + 1) — خانة فارغة") {
                                session.suspendAssistance(reason: "فتح مكتبة الأسلحة")
                                showingWeaponLibrary = true
                            }
                        }
                    }
                    Divider()
                    Button("إضافة أو ضبط الأسلحة", systemImage: "plus.circle") {
                        session.suspendAssistance(reason: "فتح مكتبة الأسلحة")
                        showingWeaponLibrary = true
                    }
                } label: {
                    Label("ضبط السلاح", systemImage: "scope")
                        .padding(.horizontal, 12)
                        .frame(minHeight: 42)
                        .background(.black.opacity(0.66), in: Capsule())
                        .overlay(Capsule().stroke(TPPlayTheme.accent.opacity(0.45), lineWidth: 1))
                }
                .accessibilityLabel("اختيار سريع من ستة أسلحة MW3")

                Spacer(minLength: 4)

                if assistance.armed {
                    Label("مفعّلة", systemImage: "checkmark.circle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .frame(height: 35)
                        .background(.black.opacity(0.7), in: Capsule())
                } else {
                    Button("تشغيل") { assistance.armed = true }
                        .padding(.horizontal, 13)
                        .frame(minHeight: 42)
                        .background(.green.opacity(0.84), in: Capsule())
                        .accessibilityLabel("تفعيل المساعدة")
                }

                Button("إيقاف") { session.stopAssistanceNow() }
                    .padding(.horizontal, 13)
                    .frame(minHeight: 42)
                    .background(.red.opacity(0.88), in: Capsule())
                    .accessibilityLabel("إيقاف جميع المساعدات")
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)

            if showMetrics {
                if case .connected = session.state {
                    performancePanel
                        .frame(maxWidth: 230)
                }
            }
            if !savedStreamNotice.isEmpty {
                Text(savedStreamNotice)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.64), in: Capsule())
            }
            if !assistance.armed, let reason = assistance.lastStopReason {
                Text("المساعدة متوقفة: \(reason)")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.64), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .zIndex(10)
    }

    private func openStreamSettings() {
        guard !showingStreamSettings else { return }
        showsSessionMenu = false
        showingQuickSettings = false
        session.suspendAssistance(preserveActivation: true)
        showingStreamSettings = true
    }

    private func captureScoreboard() {
        // User opens the game scoreboard before pressing the capture button.
        // Capture the actual decoded Remote Play video, not a screenshot of
        // this app UI. Do not turn this one-time OCR into continuous scanning.
        guard !roster.reading else { return }
        guard let image = session.calibrationFrames.image() else {
            calibrationError = true
            return
        }
        session.suspendAssistance(preserveActivation: true)
        showingRoster = true
        Task { await roster.read(image) }
    }

    private func openCalibrationCapture() {
        session.suspendAssistance(preserveActivation: true)
        if let image = session.calibrationFrames.image() {
            calibrationShot = CalibrationShot(image: image)
        } else {
            calibrationError = true
            session.resumeAssistance()
        }
    }

    private func openOpponentCapture() {
        session.suspendAssistance(preserveActivation: true)
        if let image = session.calibrationFrames.image() {
            playerNameShot = CalibrationShot(image: image)
        } else {
            calibrationError = true
            session.resumeAssistance()
        }
    }

    private var performancePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "الإطارات المعروضة: %.0f FPS", session.measuredFPS))
            Text(session.connectionRTT.map { String(format: "RTT عند الاتصال: %.1f ms", $0) } ?? "RTT عند الاتصال: غير متاح")
            Text(session.packetLoss.map { String(format: "فقد الحزم (نافذة القياس): %.2f%%", $0) } ?? "فقد الحزم: لا توجد عينة")
            Text("RTT ليس تأخير الزر إلى الصورة").foregroundStyle(.gray)
            Text(aiAnalysis.enabled ? "تحليل الصورة: مفعّل" : "تحليل الصورة: متوقف")
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit()
        .foregroundStyle(.white).padding(10)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private var loginPINBinding: Binding<Bool> {
        Binding(
            get: {
                if case .loginPINRequired = session.state { return true }
                return false
            },
            set: { _ in }
        )
    }

    private func updateControllerPresence(_ controllers: [GCController]) {
        let connected = controllers.contains { $0.extendedGamepad != nil }
        hasExternalController = connected
        if connected {
            isEditingTouchLayout = false
            isChoosingTouchLayout = false
            showsSessionMenu = false
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            showsVirtualControls = !connected
        }
    }

    private func exitFromStream() {
        // An ended or failed connection has nothing to confirm; return immediately.
        if case .ended = session.state {
            closeSession()
        } else {
            showsExitConfirmation = true
        }
    }

    private func closeSession() {
        guard !isClosing else { return }
        showsExitConfirmation = false
        showsSessionMenu = false
        isClosing = true
        session.stop { dismiss() }
    }

    private func createPreset(named name: String) {
        let id = touchLayouts.addPreset(named: name, copying: touchLayouts.activePresetID)
        touchLayouts.setActive(id)
        showsNewPresetDialog = false
        isChoosingTouchLayout = false
        isEditingTouchLayout = true
    }

    private var controls: some View {
        ZStack {
            if showsVirtualControls {
                TouchControllerOverlay(
                    session: session,
                    editing: isEditingTouchLayout,
                    resetToken: touchLayoutResetToken,
                    presetID: touchLayouts.activePresetID,
                    revision: touchLayouts.revision,
                    passesBackgroundTouches: hasExternalController
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer()

                if isEditingTouchLayout {
                    layoutEditingBar
                } else if showsVirtualControls && showsSessionMenu {
                    sessionMenu
                        .transition(.opacity)
                }
            }

            if isChoosingTouchLayout {
                Color.black.opacity(0.52)
                    .ignoresSafeArea()
                    .onTapGesture { isChoosingTouchLayout = false }

                TouchLayoutSessionPicker(
                    store: touchLayouts,
                    onSelect: { id in
                        touchLayouts.setActive(id)
                        isChoosingTouchLayout = false
                    },
                    onEdit: {
                        isChoosingTouchLayout = false
                        isEditingTouchLayout = true
                    },
                    onNew: {
                        isChoosingTouchLayout = false
                        showsNewPresetDialog = true
                    },
                    onCancel: { isChoosingTouchLayout = false }
                )
                .frame(maxWidth: 420, maxHeight: 390)
                .padding(20)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    private var sessionMenu: some View {
        VStack(spacing: 6) {
            if showsSessionMenu {
                HStack(spacing: 0) {
                    streamMenuButton("EXIT", symbol: "rectangle.portrait.and.arrow.right", danger: true) {
                        showsSessionMenu = false
                        showsExitConfirmation = true
                    }
                    streamMenuButton(aiAnalysis.enabled ? "AI ON" : "AI OFF", symbol: "viewfinder") {
                        aiAnalysis.enabled.toggle()
                    }
                    streamMenuButton("PS", symbol: "playstation.logo") {
                        session.clickPSButton()
                    }
                    streamMenuButton("SETTINGS", symbol: "gearshape.2") {
                        showsSessionMenu = false
                        openStreamSettings()
                    }
                    streamMenuButton("LAYOUT", symbol: "slider.horizontal.3", disabled: !showsVirtualControls) {
                        showsSessionMenu = false
                        isChoosingTouchLayout = true
                    }
                }
                .frame(width: 360, height: 48)
                .background(TPPlayTheme.surface.opacity(0.35))
                .overlay { Rectangle().stroke(TPPlayTheme.violet.opacity(0.4), lineWidth: 1) }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    showsSessionMenu.toggle()
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(showsSessionMenu ? TPPlayTheme.accent.opacity(0.8) : TPPlayTheme.primaryText.opacity(0.55))
                    .frame(width: 58, height: 30)
                    .background(TPPlayTheme.primaryText.opacity(showsSessionMenu ? 0.2 : 0.13))
                    .overlay { Rectangle().stroke(TPPlayTheme.violet.opacity(0.25), lineWidth: 1) }
                    .frame(width: 58, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsSessionMenu ? "Close session controls" : "Open session controls")
        }
        .padding(.bottom, 6)
    }

    private func streamMenuButton(
        _ title: String,
        symbol: String,
        danger: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(0.55)
            .foregroundStyle(danger ? TPPlayTheme.danger : TPPlayTheme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.32 : 1)
        .overlay(alignment: .leading) { Rectangle().fill(TPPlayTheme.border.opacity(0.72)).frame(width: 1) }
    }

    private var layoutEditingBar: some View {
        HStack(spacing: 0) {
            Button("RESET") { touchLayoutResetToken += 1 }
                .frame(width: 92, height: 42)
                .buttonStyle(AcidButtonStyle())
            Text("DRAG TO MOVE  //  PINCH TO SCALE")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.65)
                .foregroundStyle(TPPlayTheme.primaryText)
                .frame(width: 240, height: 42)
                .background(TPPlayTheme.surface.opacity(0.9))
                .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
            Button("إلغاء") {
                touchLayouts.restoreSavedLayouts()
                isEditingTouchLayout = false
            }
            .frame(width: 76, height: 42)
            .buttonStyle(AcidButtonStyle())
            Button("حفظ") {
                if touchLayouts.saveLayouts() {
                    savedStreamNotice = "تم حفظ أماكن أزرار اللمس."
                    isEditingTouchLayout = false
                }
            }
            .frame(width: 76, height: 42)
            .buttonStyle(AcidButtonStyle(active: true))
        }
        .padding(.bottom, 8)
    }
}

private struct TouchLayoutSessionPicker: View {
    @ObservedObject var store: TouchLayoutStore
    let onSelect: (UUID) -> Void
    let onEdit: () -> Void
    let onNew: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(TPPlayTheme.accent)
                    .frame(width: 8, height: 8)
                Text("// CONTROL PRESET")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .black))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(.leading, 16)
            .frame(height: 44)
            .background(TPPlayTheme.surfaceRaised.opacity(0.96))
            .overlay(alignment: .bottom) { Rectangle().fill(TPPlayTheme.violet).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.presets) { preset in
                        let selected = preset.id == store.activePresetID
                        Button { onSelect(preset.id) } label: {
                            HStack(spacing: 12) {
                                Rectangle()
                                    .fill(selected ? TPPlayTheme.accent : TPPlayTheme.violet)
                                    .frame(width: 8, height: 8)
                                Text(preset.name)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .tracking(0.55)
                                    .lineLimit(1)
                                Spacer()
                                if selected {
                                    Text("LAST USED")
                                        .font(.system(size: 8, weight: .black, design: .monospaced))
                                        .tracking(0.7)
                                        .foregroundStyle(TPPlayTheme.accent)
                                }
                            }
                            .foregroundStyle(TPPlayTheme.primaryText)
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                            .background(selected ? TPPlayTheme.accent.opacity(0.07) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(TPPlayTheme.border.opacity(0.72)).frame(height: 1) }
                    }
                }
            }

            HStack(spacing: 0) {
                Button("NEW PRESET +", action: onNew)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .buttonStyle(AcidButtonStyle())
                Button("EDIT SELECTED >", action: onEdit)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .buttonStyle(AcidButtonStyle(active: true))
            }
        }
        .background(TPPlayTheme.surface.opacity(0.96))
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }
}

private struct StreamExitDialog: View {
    let onExit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(TPPlayTheme.onAccent).frame(width: 8, height: 8)
                Text("// END REMOTE PLAY")
                Spacer()
                Text("EXIT")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(TPPlayTheme.danger)

            VStack(alignment: .leading, spacing: 16) {
                Text("DISCONNECT FROM THE CONSOLE?")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(TPPlayTheme.primaryText)
                HStack(spacing: 8) {
                    Button("NO // KEEP PLAYING", action: onCancel)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle())
                    Button("YES // EXIT", action: onExit)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(TPPlayTheme.danger)
                }
            }
            .padding(16)
            .background(TPPlayTheme.surface)
        }
        .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 1) }
    }
}

private struct StreamPresetNameDialog: View {
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(TPPlayTheme.accent).frame(width: 8, height: 8)
                Text("// NEW CONTROL PRESET")
                Spacer()
                Text("MAP")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(TPPlayTheme.surfaceRaised)
            .overlay(alignment: .bottom) { Rectangle().fill(TPPlayTheme.violet).frame(height: 1) }

            VStack(alignment: .leading, spacing: 14) {
                Text("COPIES THE CURRENT LAYOUT // ENTER A PRESET NAME")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(TPPlayTheme.secondaryText)
                TextField("GAME / LAYOUT NAME", text: $name)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(AcidFieldStyle())
                    .focused($focused)
                HStack(spacing: 8) {
                    Button("CANCEL", action: onCancel)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle())
                    Button("CREATE") { onCreate(name) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle(active: true))
                }
            }
            .padding(16)
            .background(TPPlayTheme.surface)
        }
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
        .onAppear { focused = true }
    }
}


/// All existing app settings stay reachable while the PS5 Remote Play session
/// remains connected. Controller assistance is suspended by the presenting
/// view and restored on dismissal; no reconnect or logout is triggered here.
private struct InStreamSettingsCenter: View {
    @ObservedObject var session: RemotePlaySession
    @ObservedObject private var diagnostics = VelmiraLiveDiagnostics.shared
    @ObservedObject private var assistance = AssistanceState.shared
    @ObservedObject private var ai = AIAnalysisState.shared
    @ObservedObject private var layouts = TouchLayoutStore.shared
    @ObservedObject private var roster = MatchRoster.shared
    @Binding var showMetrics: Bool
    let onClose: () -> Void
    let onCalibrate: () -> Void
    let onScanTeams: () -> Void
    @State private var notice = ""
    @State private var exportLog: VelmiraDiagnosticLogDocument?
    @State private var showingLogExporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("تستطيع تعديل كل إعدادات Velmira من هنا دون إنهاء بث PS5. يتم إيقاف أوامر المساعدة مؤقتاً طوال فتح لوحة الإعدادات.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    VelmiraSection("التحكم السريع أثناء البث") {
                        Toggle("تشغيل تحليل YOLOv8n", isOn: $ai.enabled)
                        Toggle("إظهار مربعات اللاعبين والأسماء", isOn: $ai.showPlayerBoxes)
                        Toggle("تأكيد الاكتشاف قبل عرض النتيجة", isOn: $ai.precisionMode)
                        Toggle("إظهار موضع الجسم المختار", isOn: $ai.adaptiveBodyMarker)
                        Toggle("لوحة قياسات الأداء", isOn: $showMetrics)
                        scale("ثقة الكشف", value: $ai.threshold, range: 0.20...0.95)
                        scale("قوة التصحيح", value: $assistance.configuration.strength, range: 0.1...5)
                        scale("نطاق التتبع", value: $assistance.configuration.radius, range: 0.05...0.5)
                        scale("تنعيم الحركة", value: $assistance.configuration.response, range: 0.02...0.5)
                        scale("ارتفاع النقطة على الجسم", value: $assistance.configuration.pointY, range: 0...1)
                        Picker("تحليل YOLO في الثانية", selection: $ai.rate) {
                            Text("3").tag(3.0)
                            Text("5").tag(5.0)
                            Text("8").tag(8.0)
                            Text("12").tag(12.0)
                            Text("20").tag(20.0)
                            Text("24").tag(24.0)
                        }.pickerStyle(.menu)
                        Text("معدل التحليل المطلوب ليس FPS مضموناً؛ عند الضغط الحراري يخفض التطبيق السرعة تلقائياً.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            let a = assistance.saveSettings()
                            let b = ai.saveSettings()
                            let c = layouts.saveLayouts()
                            UserDefaults.standard.set(showMetrics, forKey: "velmira.showMetrics.compact.v2")
                            notice = a && b && c ? "حُفظت إعدادات التحكم والذكاء والأزرار والأداء."
                                                 : "تعذّر حفظ بعض الإعدادات."
                        } label: {
                            Label("حفظ جميع التعديلات السريعة", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(AcidButtonStyle(active: true))
                        if !notice.isEmpty {
                            Text(notice).font(.footnote).foregroundStyle(.cyan)
                        }
                    }
                    VelmiraSection("الاستعادة ومراقبة الأداء") {
                        Text("بث PS5: \(Int(session.measuredFPS)) FPS — الشبكة: \(session.packetLoss.map { String(format: "%.1f%%", $0) } ?? "لا توجد قياسات")")
                        Text("YOLO: \(Int(diagnostics.measuredYOLOms))ms — الحد الذكي: \(String(format: "%.1f", diagnostics.analysisRate)) تحليل/ث — إطارات مؤجلة: \(diagnostics.droppedBusy)")
                        Text("حرارة الجهاز: \(diagnostics.thermalDescription)")
                        Text("قراءة الأسماء: \(diagnostics.lastOCRStatus)")
                        Text("الأرقام تقريبية ولا تمثل زمن استجابة يد التحكم.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("حفظ نقطة استعادة قبل التعديل") {
                            do {
                                try VelmiraSettingsCheckpoint.save()
                                notice = "حُفظت نقطة استعادة لجميع الإعدادات."
                            } catch { notice = error.localizedDescription }
                        }
                        Button("التراجع إلى نقطة الاستعادة", role: .destructive) {
                            do {
                                try VelmiraSettingsCheckpoint.restore()
                                notice = "تمت استعادة الإعدادات والمساعدة متوقفة."
                                VelmiraLiveDiagnostics.shared.record("SETTINGS", "استعادة الإعدادات السابقة")
                            } catch { notice = error.localizedDescription }
                        }.disabled(!VelmiraSettingsCheckpoint.exists)
                        Button("تصدير سجل الأخطاء والأداء") {
                            exportLog = VelmiraDiagnosticLogDocument(text: diagnostics.exportText)
                            showingLogExporter = true
                        }
                        Button("مسح سجل الأخطاء", role: .destructive) { diagnostics.clear() }
                        Text("السجل محلي، لا يسجل الأسماء أو صور اللعبة أو بيانات PSN.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VelmiraSection("أقسام الإعدادات الكاملة") {
                        link("التحكم والتتبع — جميع الأشرطة والماكروز والارتداد",
                             icon: "scope") { AssistanceSettings() }
                        link("الذكاء الاصطناعي — الألوان والكشف والأداء",
                             icon: "viewfinder") { AIAnalysisSettings() }
                        link("أسلحة MW3 — كل الأسلحة والاختصارات الستة",
                             icon: "square.stack.3d.up") { MW3WeaponCatalogView() }
                        link("قائمة فريقك والخصوم — الأسماء والتصنيف",
                             icon: "person.2.fill") { MatchRosterView() }
                        link("أزرار اللمس والعصي — المواضع والحساسية",
                             icon: "hand.draw") { TouchLayoutSettingsView() }
                        link("جودة بث PS5 — الدقة والإطارات والبتريت",
                             icon: "tv") { VelmiraAdvancedSettings() }
                        link("ملفات الألعاب — الحفظ والتحميل والتبديل",
                             icon: "square.stack") { VelmiraToolsView() }
                        link("استيراد وتصدير ملف JSON شامل",
                             icon: "square.and.arrow.up.on.square") { VelmiraSettingsTransferPanel() }
                        link("اختبار يد التحكم",
                             icon: "gamecontroller") { ControllerTestView() }
                        link("تشخيص اتصال PS5",
                             icon: "wifi") { LinkDiagnosticView() }
                        link("الاتصال عبر الإنترنت و5G",
                             icon: "globe") { RemotePlayInternetSettingsView() }
                    }
                    VelmiraSection("إجراءات البث المباشرة") {
                        Button(action: onCalibrate) {
                            Label("التقاط شاشة PS5 لمعايرة اللون والنقطة", systemImage: "scope")
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(AcidButtonStyle())
                        Button(action: onScanTeams) {
                            Label("قراءة أسماء الفريقين من لوحة النتائج", systemImage: "person.text.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(AcidButtonStyle())
                        Text("قائمة اللاعبين المحفوظة: فريقي \(roster.names.filter { $0.side == .friendly }.count) • الخصوم \(roster.names.filter { $0.side == .opponent }.count). افتح لوحة النتائج قبل التصوير.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("تغيير دقة البث ومعدل الإطارات والبتريت يسري في جلسة الاتصال التالية، أما إعدادات التحليل فتسري مباشرة بعد إغلاق هذه اللوحة.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(18)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(TPPlayTheme.canvas)
            .navigationTitle("إعدادات البث الكاملة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("العودة للبث", action: onClose)
                }
            }
        }
        .fileExporter(isPresented: $showingLogExporter,
                      document: exportLog, contentType: .plainText,
                      defaultFilename: "Velmira-Local-Diagnostics") { outcome in
            if case .failure(let error) = outcome { notice = error.localizedDescription }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func scale(_ label: String, value: Binding<Double>,
                       range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.cyan)
            }
            Slider(value: value, in: range)
        }
    }

    private func link<Destination: View>(
        _ title: String, icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 23)
                Text(title).font(.subheadline).multilineTextAlignment(.leading)
                Spacer(minLength: 2)
                Image(systemName: "chevron.left").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 43)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .background(TPPlayTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}


/// Non-modal overlay: game frames remain visible behind the compact controls.
private struct InStreamQuickControls: View {
    @ObservedObject var session: RemotePlaySession
    @ObservedObject private var ai = AIAnalysisState.shared
    @ObservedObject private var diagnostics = VelmiraLiveDiagnostics.shared
    @ObservedObject private var games = GameProfiles.shared
    @State private var profileName = "MW3"
    @State private var feedback = ""
    let onFullSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("لوحة البث السريعة", systemImage: "slider.horizontal.3").font(.subheadline.bold())
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .accessibilityLabel("إغلاق إعدادات البث السريعة")
            }
            Toggle("تحليل YOLO", isOn: $ai.enabled)
            Toggle("إظهار أسماء اللاعبين والمربعات", isOn: $ai.showPlayerBoxes)
            HStack { Text("ثقة الكشف"); Spacer(); Text("\(Int(ai.threshold * 100))٪").monospacedDigit() }
                .font(.caption)
            Slider(value: $ai.threshold, in: 0.20...0.95, step: 0.05)
            HStack(spacing: 7) {
                Text("FPS: \(Int(session.measuredFPS))")
                Text("AI: \(Int(diagnostics.measuredYOLOms))ms")
                Text("الحرارة: \(diagnostics.thermalDescription)").lineLimit(1)
            }.font(.caption2).foregroundStyle(.secondary)
            Menu {
                ForEach(games.profiles) { profile in
                    Button(profile.name) {
                        games.apply(profile)
                        feedback = "تم تحميل \(profile.name) مؤقتاً، افتح ملف الألعاب لحفظه."
                    }
                }
                if games.profiles.isEmpty { Text("لا توجد ملفات محفوظة") }
            } label: {
                Label("اختيار ملف لعبة محفوظ", systemImage: "square.stack")
            }
            HStack {
                TextField("اسم ملف اللعبة", text: $profileName).textFieldStyle(.roundedBorder)
                Button("حفظ") { games.save(profileName); feedback = games.message }
                    .buttonStyle(.bordered)
            }
            HStack {
                Button("حفظ التعديلات") {
                    let a = ai.saveSettings()
                    let b = AssistanceState.shared.saveSettings()
                    feedback = a && b ? "تم الحفظ" : "فشل الحفظ"
                }.buttonStyle(.bordered)
                Button("كل الإعدادات", action: onFullSettings)
                    .buttonStyle(.borderedProminent)
            }
            if !feedback.isEmpty { Text(feedback).font(.caption2).lineLimit(2) }
        }
        .font(.caption).foregroundStyle(.white).padding(12)
        .background(.black.opacity(0.93), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15)
                    .stroke(TPPlayTheme.accent.opacity(0.65), lineWidth: 1))
    }
}

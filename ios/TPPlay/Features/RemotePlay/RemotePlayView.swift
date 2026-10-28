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
    @AppStorage("velmira.showMetrics") private var showMetrics = true
    @State private var calibrationShot: CalibrationShot?
    @State private var playerNameShot: CalibrationShot?
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
            AIFrameAnalyzer.shared.setPaused(false)
            session.resumeAssistance()
            let controllers = GCController.controllers()
            controllers.forEach(session.attach)
            updateControllerPresence(controllers)
            GCController.startWirelessControllerDiscovery()
            UIApplication.shared.isIdleTimerDisabled = true
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
            TPPlayOrientation.set(.portrait)
            GCController.stopWirelessControllerDiscovery()
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                TPPlayOrientation.set(.landscape)
                AIFrameAnalyzer.shared.setPaused(false)
                if calibrationShot == nil && playerNameShot == nil { session.resumeAssistance() }
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
                    Button("معايرة اللون", systemImage: "eyedropper") {
                        openCalibrationCapture()
                    }
                    Button("اسم خصم", systemImage: "text.viewfinder") {
                        openOpponentCapture()
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
                } label: {
                    Label("الأدوات", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 13)
                        .frame(minHeight: 42)
                        .background(.black.opacity(0.66), in: Capsule())
                        .overlay(Capsule().stroke(TPPlayTheme.accent.opacity(0.45), lineWidth: 1))
                }
                .accessibilityLabel("أدوات البث والإعدادات")

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
                performancePanel
                    .frame(maxWidth: 230)
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
            Button("DONE") { isEditingTouchLayout = false }
                .frame(width: 92, height: 42)
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

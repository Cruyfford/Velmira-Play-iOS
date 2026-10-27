import AuthenticationServices
import SwiftUI
import UIKit

struct HomeView: View {
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
    @AppStorage("streamResolution") private var resolution = 1080
    @AppStorage("streamFPS") private var fps = 60
    @AppStorage("streamBitrate") private var bitrate = 15_000
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
                    .buttonStyle(AcidButtonStyle(active: true))
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
        .fullScreenCover(isPresented: $showingTouchLayouts) {
            TouchLayoutSettingsView()
        }
        .fullScreenCover(isPresented: $showingLinkDiagnostic) {
            LinkDiagnosticView()
        }
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

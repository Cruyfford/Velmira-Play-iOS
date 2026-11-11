import SwiftUI
import AVKit
import AVFoundation
import UIKit

@main
struct VelmiraAnimeApp: App {
    @StateObject private var session = Session()
    @StateObject private var catalog = CatalogStore()
    @StateObject private var history = HistoryStore()

    init() {
        // Play sound even when the silent switch is on, and allow PiP.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        // Dark, slightly translucent tab bar like streaming apps.
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(white: 0.05, alpha: 0.96)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(catalog)
                .environmentObject(history)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Player

/// Owns the AVPlayer and reports why playback failed instead of showing a blank screen.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var errorText: String?
    let player: AVPlayer
    private var statusObs: NSKeyValueObservation?

    init(item: PlayItem) {
        var headers: [String: String] = [
            "Referer": providerReferer,
            "Origin": providerOrigin,
            "User-Agent": providerUA
        ]
        if !item.cookie.isEmpty { headers["Cookie"] = item.cookie }
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        if let cookies = HTTPCookieStorage.shared.cookies(for: item.url), !cookies.isEmpty {
            options[AVURLAssetHTTPCookiesKey] = cookies
        }
        let asset = AVURLAsset(url: item.url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = true
        let host = item.url.host ?? ""
        statusObs = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            let ns = it.error as NSError?
            var text = ns?.localizedDescription ?? "تعذر تشغيل الفيديو"
            if let under = ns?.userInfo[NSUnderlyingErrorKey] as? NSError {
                text += "\n(\(under.domain) \(under.code))"
            }
            text += "\n" + host
            Task { @MainActor in self?.errorText = text }
        }
        player.play()
    }

    func stop() { player.pause() }
}

struct PlayerScreen: View {
    let item: PlayItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PlayerModel

    init(item: PlayItem) {
        self.item = item
        _model = StateObject(wrappedValue: PlayerModel(item: item))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PlayerController(player: model.player)
                .ignoresSafeArea()
                .environment(\.layoutDirection, .leftToRight)
            if let err = model.errorText {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Color.yellow)
                    Text("تعذر تشغيل الحلقة").font(.headline)
                    Text(err).font(.footnote).multilineTextAlignment(.center).foregroundStyle(Color.white.opacity(0.8))
                        .textSelection(.enabled)
                }
                .padding(20)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                model.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.55))
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
        }
        .statusBarHidden()
        .onDisappear { model.stop() }
    }
}

struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

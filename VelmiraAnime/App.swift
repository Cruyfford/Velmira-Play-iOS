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

/// Full-screen native player. The provider's media host expects the site
/// Referer/Origin and a mobile UA (same headers the Worker uses).
struct PlayerScreen: View {
    let item: PlayItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                PlayerController(player: player)
                    .ignoresSafeArea()
                    .environment(\.layoutDirection, .leftToRight)
            }
            Button {
                player?.pause()
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
        .onAppear(perform: start)
        .onDisappear { player?.pause() }
    }

    private func start() {
        guard player == nil else { return }
        let headers: [String: String] = [
            "Referer": providerReferer,
            "Origin": providerOrigin,
            "User-Agent": providerUA
        ]
        let asset = AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: playerItem)
        p.allowsExternalPlayback = true
        player = p
        p.play()
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

import SwiftUI
import UIKit

// Rotate the live Remote Play screen only. The rest of the app remains portrait.
@MainActor
enum TPPlayOrientation {
    static var supported: UIInterfaceOrientationMask = .portrait

    static func set(_ orientation: UIInterfaceOrientationMask) {
        supported = orientation
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
                // A scene may be transitioning or inactive; the preferred mask
                // remains set and can be reapplied on foreground activation.
                NSLog("[VELMIRA-ORIENTATION] Scene update rejected: %@", error.localizedDescription)
            }
        }
    }
}

final class TPPlayOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        TPPlayOrientation.supported
    }
}

@main
struct TPPlayApp: App {
    @UIApplicationDelegateAdaptor(TPPlayOrientationDelegate.self) private var orientationDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

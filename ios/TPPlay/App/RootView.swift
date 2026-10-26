import SwiftUI
struct RootView: View {
    var body: some View {
        TabView {
            ConsoleLibraryView().tabItem { Label("PS5", systemImage: "gamecontroller.fill") }
            AIAnalysisSettings().tabItem { Label("الذكاء الاصطناعي", systemImage: "viewfinder") }
            AssistanceSettings().tabItem { Label("التحكم", systemImage: "scope") }
            HomeView().tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
    }
}

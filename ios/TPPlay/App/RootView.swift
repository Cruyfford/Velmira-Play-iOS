import SwiftUI
struct RootView: View {
    var body: some View {
        TabView {
            ConsoleLibraryView().environment(\.layoutDirection, .rightToLeft)
                .tabItem { Label("PS5", systemImage: "gamecontroller.fill") }
            AIAnalysisSettings().tabItem { Label("الذكاء الاصطناعي", systemImage: "viewfinder") }
            AssistanceSettings().tabItem { Label("التحكم", systemImage: "scope") }
            VelmiraToolsView().tabItem { Label("الأدوات", systemImage: "wrench.and.screwdriver") }
            HomeView().tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
        .preferredColorScheme(.dark)
        .tint(TPPlayTheme.accent)
        .toolbarBackground(TPPlayTheme.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

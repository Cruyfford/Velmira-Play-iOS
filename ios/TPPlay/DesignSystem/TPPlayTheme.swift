import SwiftUI

enum TPPlayTheme {
    static let canvas = Color(red: 0.015, green: 0.035, blue: 0.075)
    static let surface = Color(red: 0.045, green: 0.075, blue: 0.13)
    static let surfaceRaised = Color(red: 0.075, green: 0.12, blue: 0.20)
    static let border = Color(red: 0.20, green: 0.29, blue: 0.43)
    static let accent = Color(red: 0.08, green: 0.83, blue: 0.95)
    static let violet = Color(red: 0.44, green: 0.36, blue: 0.95)
    static let onAccent = Color.white
    static let primaryText = Color(red: 0.95, green: 0.97, blue: 1)
    static let secondaryText = Color(red: 0.64, green: 0.72, blue: 0.86)
    static let tertiaryText = Color(red: 0.49, green: 0.59, blue: 0.73)
    static let danger = Color(red: 1, green: 0.3, blue: 0.4)
    static let gradient = LinearGradient(colors: [accent, Color(red: 0.04, green: 0.32, blue: 1)], startPoint: .leading, endPoint: .trailing)
}

struct TPPageHeader<Actions: View>: View {
    let title: String
    private let actions: Actions
    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.actions = actions()
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("VELMIRA PLAY").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(TPPlayTheme.accent)
                Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(TPPlayTheme.primaryText)
            }
            Spacer(minLength: 8)
            actions
        }.padding(.vertical, 8)
    }
}
extension TPPageHeader where Actions == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

struct AcidButtonStyle: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TPPlayTheme.primaryText)
            .background {
                if active { TPPlayTheme.gradient }
                else { TPPlayTheme.surfaceRaised }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(active ? TPPlayTheme.accent.opacity(0.55) : TPPlayTheme.border.opacity(0.7), lineWidth: 1) }
            .shadow(color: active ? TPPlayTheme.accent.opacity(0.14) : .clear, radius: 10, y: 4)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
struct AcidFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.font(.system(size: 15)).foregroundStyle(TPPlayTheme.primaryText)
            .padding(.horizontal, 16).frame(height: 52)
            .background(TPPlayTheme.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}
struct TPTerminalActivityGlyph: View {
    var color = TPPlayTheme.accent
    var body: some View { ProgressView().tint(color).frame(width: 20, height: 20) }
}
struct TPErrorDialog: View {
    let title: String
    let message: String
    let dismiss: () -> Void
    var body: some View {
        VelmiraSection(title) {
            Image(systemName: "exclamationmark.circle").font(.largeTitle).foregroundStyle(TPPlayTheme.danger)
            Text(message).font(.body)
            Button("حسناً", action: dismiss).frame(maxWidth: .infinity, minHeight: 50)
                .buttonStyle(AcidButtonStyle(active: true))
        }
    }
}
struct VelmiraSection<Content: View>: View {
    var title: String
    @ViewBuilder let content: Content
    init(_ title: String = "", @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !title.isEmpty {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(TPPlayTheme.primaryText)
            }
            content
        }
        .font(.system(size: 15))
        .foregroundStyle(TPPlayTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(LinearGradient(colors: [TPPlayTheme.surfaceRaised.opacity(0.8), TPPlayTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(TPPlayTheme.border.opacity(0.65), lineWidth: 1) }
    }
}
struct VelmiraConsoleArtwork: View {
    var body: some View {
        ZStack {
            Circle().fill(TPPlayTheme.accent.opacity(0.12)).frame(width: 130, height: 130).blur(radius: 16)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.white, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 23, height: 102).rotationEffect(.degrees(7))
                RoundedRectangle(cornerRadius: 5).fill(Color.black).frame(width: 20, height: 98)
                    .overlay(alignment: .leading) { Capsule().fill(TPPlayTheme.accent).frame(width: 2, height: 80) }
                RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.white, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 23, height: 108).rotationEffect(.degrees(-7))
            }
            Image(systemName: "gamecontroller.fill").font(.system(size: 45)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 4).offset(x: 30, y: 46)
        }.frame(width: 150, height: 155).accessibilityHidden(true)
    }
}

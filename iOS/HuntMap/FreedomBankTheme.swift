import SwiftUI

struct FBTheme {
    static let background = HuntReference.background
    static let panel = HuntReference.card
    static let panel2 = HuntReference.raised
    static let stroke = Color.white.opacity(0.06)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
    static let green = HuntReference.green
    static let mint = HuntReference.mint
    static let cyan = Color(red: 0.28, green: 0.78, blue: 0.91)
    static let warning = Color.orange
    static let danger = Color(red: 1.00, green: 0.35, blue: 0.35)
}

struct FBCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(FBTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(FBTheme.stroke, lineWidth: 1)
            )
    }
}

struct FBSoftCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(FBTheme.panel2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FBTheme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func fbCard() -> some View { modifier(FBCardModifier()) }
    func fbSoftCard() -> some View { modifier(FBSoftCardModifier()) }
    func fbScreenBackground() -> some View {
        self.background(
            LinearGradient(colors: [Color.black, Color(red: 0.05, green: 0.06, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}

struct FBActionPill: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(FBTheme.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(FBTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FBTheme.panel2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(FBTheme.stroke, lineWidth: 1))
    }
}

struct FBTabButton: View {
    let title: String
    let systemImage: String
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? FBTheme.green.opacity(0.15) : Color.clear)
                    .frame(width: 42, height: 32)
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(active ? FBTheme.green : Color.white.opacity(0.65))
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? FBTheme.green : Color.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

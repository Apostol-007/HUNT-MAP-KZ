import SwiftUI

/// Reusable UI primitives matching the eight-screen HUNT MAP KZ visual reference.
/// Pure presentation: never fabricates GPS, weather, wildlife or geographic data.
enum HuntReference {
    static let background = Color(red: 0.018, green: 0.032, blue: 0.031)
    static let card = Color(red: 0.092, green: 0.112, blue: 0.108)
    static let raised = Color(red: 0.13, green: 0.15, blue: 0.15)
    static let green = Color(red: 0.13, green: 0.87, blue: 0.38)
    static let mint = Color(red: 0.40, green: 0.94, blue: 0.59)
    static let muted = Color(red: 0.61, green: 0.67, blue: 0.65)
    static let separator = Color.white.opacity(0.07)
}

struct ReferenceActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(HuntReference.green)
                    .frame(width: 43, height: 43)
                    .background(HuntReference.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(HuntReference.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
            .padding(15)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ReferencePrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(colors: [HuntReference.mint, HuntReference.green],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

struct ReferenceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : .white.opacity(0.82))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(selected ? HuntReference.green : HuntReference.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ReferencePageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(HuntReference.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReferenceLayerRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var enabled: Bool
    var available = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(available ? HuntReference.green : HuntReference.muted)
                .frame(width: 40, height: 40)
                .background(HuntReference.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                Text(detail).font(.caption2).foregroundStyle(HuntReference.muted)
            }
            Spacer(minLength: 4)
            Toggle(title, isOn: $enabled)
                .labelsHidden()
                .tint(HuntReference.green)
                .disabled(!available)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .opacity(available ? 1 : 0.65)
    }
}

struct ReferenceMenuRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(HuntReference.green)
                    .frame(width: 30)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(HuntReference.muted)
            }
            .frame(minHeight: 54)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ReferenceEmptyCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(HuntReference.green)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.footnote).foregroundStyle(HuntReference.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

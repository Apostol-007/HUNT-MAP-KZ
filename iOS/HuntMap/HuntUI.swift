import SwiftUI

// Shared field UI: one palette, 16-point surfaces, 44-point touch targets.
extension View {
    func huntSurface() -> some View {
        self.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 18))
    }
    func huntModal() -> some View {
        self.tint(HuntReference.green)
            .environment(\.locale, Locale(identifier: "ru_KZ"))
            .preferredColorScheme(.dark)
            .presentationBackground(HuntReference.background)
    }
}
struct HuntAction: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .foregroundStyle(primary ? Color.black : HuntReference.green)
                .background(primary ? HuntReference.green : HuntReference.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}
struct HuntSearchField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(HuntReference.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.subheadline)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 13).frame(minHeight: 48)
        .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct HuntRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(HuntReference.green).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(HuntReference.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(HuntReference.muted)
        }.huntSurface()
    }
}

import SwiftUI

struct WhatsNewSheet: View {
    let release: WhatsNewRelease
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            VStack(alignment: .leading, spacing: 22) {
                Text("What's new")
                    .font(DisplayFont.display(32))
                    .tracking(-1)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(release.items) { item in row(item) }
                }

                Spacer(minLength: 0)

                WelcomePrimaryButton(title: String(localized: "Got it"), action: onDismiss)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .analyticsScreen(.whatsNew)
    }

    private func row(_ item: WhatsNewRelease.Item) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

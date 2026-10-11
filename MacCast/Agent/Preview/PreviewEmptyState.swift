import SwiftUI

/// A tile, a heading and a line of explanation: what the preview shows before there is a page, and when a page could not be opened.
struct PreviewEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: symbol, size: 60)
            Text(verbatim: title)
                .font(DisplayFont.display(23))
                .tracking(-0.6)
                .foregroundStyle(ColorPalette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text(verbatim: detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

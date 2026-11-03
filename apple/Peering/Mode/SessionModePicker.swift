import PeeringKit
import SwiftUI

/// The choice offered when a session is ready: the Mac's screen, its agents and files, or a remote with no picture.
struct SessionModePicker: View {
    let modes: [SessionMode]
    let hostName: String
    let onChoose: (SessionMode) -> Void
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TabScreenHeader(
                String(localized: "How do you want to use \(hostName)?"),
                detail: String(localized: "You can change this at any time from the session menu.")
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, onCancel == nil ? 0 : 36)

            VStack(spacing: 12) {
                ForEach(modes) { mode in
                    Button { onChoose(mode) } label: { tile(mode) }
                        .buttonStyle(RailButtonStyle(scale: 0.98))
                }
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorPalette.backdrop.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(ColorPalette.ink)
                .padding(.trailing, 8)
                .padding(.top, 14)
                .accessibilityLabel(String(localized: "Close"))
            }
        }
    }

    /// Each tile takes an equal share of the height left under the header, so three of them fill the screen.
    private func tile(_ mode: SessionMode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IconTile(symbol: mode.symbol, size: 56)
            Spacer(minLength: 16)
            Text(mode.title)
                .font(.title2.weight(.semibold))
            Text(mode.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
        .foregroundStyle(ColorPalette.ink)
        .cardSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

import PeeringKit
import SwiftUI

/// The choice offered when a session is ready: the Mac's screen, its agents and files, or a remote with no picture.
struct SessionModePicker: View {
    let modes: [SessionMode]
    let hostName: String
    let onChoose: (SessionMode) -> Void
    var onCancel: (() -> Void)?

    @AppStorage(PreferenceKeys.asksSessionModeOnConnect) private var asksOnConnect = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Controls.toggle(
                        String(localized: "Ask every time I connect"),
                        systemImage: "square.grid.2x2",
                        isOn: $asksOnConnect
                    )
                    Text(String(localized: "You can change this at any time from the session menu."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                VStack(spacing: 12) {
                    ForEach(modes) { mode in
                        Button { onChoose(mode) } label: { tile(mode) }
                            .buttonStyle(RailButtonStyle(scale: 0.98))
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, ChromeMetrics.edgeInset)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ColorPalette.backdrop.ignoresSafeArea())
            .navigationTitle(hostName)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onCancel) { Image(systemName: "xmark") }
                            .accessibilityLabel(String(localized: "Close"))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
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

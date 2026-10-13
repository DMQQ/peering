import SwiftUI

/// Shown where Macs would be listed when the system is refusing Local Network access. Without it the list is just empty, which reads as "no Mac is running" and sends the person to the wrong machine.
struct LocalNetworkNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Local Network is off", systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ColorPalette.ink)
            Text("Peering needs it to find your Mac on this Wi-Fi. Turn on Local Network for Peering in Settings, and the list fills in by itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ColorPalette.ink, in: Capsule())
            }
            .buttonStyle(RailButtonStyle(scale: 0.97))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

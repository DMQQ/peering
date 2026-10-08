import AppKit
import RemoteCore
import SwiftUI

extension HostStatusView {
    /// Buttons, not a source-list List: that paints every symbol in the accent colour and ignores foregroundStyle on the Label.
    var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().opacity(0.45)
            VStack(spacing: 2) {
                ForEach(Array(HostSection.allCases.enumerated()), id: \.element) { index, item in
                    sidebarRow(item)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            // Shown only where it fits: the window sizes to its content, so a card that forced
            // height here made the sidebar taller than the screen and looped layout into a crash.
            ViewThatFits(in: .vertical) {
                sidebarQRCode
                Color.clear.frame(height: 0)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            if let version = updater.availableVersion {
                updateBanner(version)
                    .padding(10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(HostMotion.state, value: updater.availableVersion)
        .background(HostPalette.backdrop)
    }

    @ViewBuilder
    var sidebarQRCode: some View {
        if PairingPayload.canonicalIdentifier(model.deviceID) != nil,
           let image = qrCode(encoding: PairingPayload.encode(hostID: model.deviceID)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add this Mac")
                    .font(HostDisplayFont.display(15))
                    .tracking(-0.2)
                    .foregroundStyle(HostPalette.ink)
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("This Mac's device ID, as a QR code")
                Text("Scan with Peering on your iPhone, from any network.")
                    .font(.caption2)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hostPanel(cornerRadius: HostPalette.panelRadius - 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .opacity(model.status.isListening ? 1 : 0.4)
            .help(model.status.isListening ? model.deviceID : String(localized: "Press Start first: a Mac that is not hosting cannot be reached by this code."))
        }
    }

    func updateBanner(_ version: String) -> some View {
        Button { updater.install() } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(HostPalette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HostPalette.ink)
                    Text(updater.readyToInstall ? String(localized: "Version \(version). Click to restart and update.") : String(localized: "Version \(version). Click to install."))
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                HostPalette.accent.opacity(0.16),
                in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                    .strokeBorder(HostPalette.accent.opacity(0.4))
            )
            .contentShape(RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!updater.canCheck)
    }

    /// Selection is a fill rather than a tint, as on the phone: a coloured glyph is hard to find at arm length.
    func sidebarRow(_ item: HostSection) -> some View {
        let isSelected = section == item
        return Button {
            withAnimation(HostMotion.state) { section = item }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? HostPalette.ink : HostPalette.muted)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                isSelected
                    ? AnyShapeStyle(HostPalette.accent)
                    : AnyShapeStyle(hoveredSection == item ? HostPalette.raised : .clear),
                in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredSection = hovering ? item : nil }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The app icon rather than an SF Symbol, to match the Dock; the state is the sentence below.
    var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .shadow(color: Color.black.opacity(0.16), radius: 7, y: 3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Peering")
                        .font(HostDisplayFont.display(19))
                        .tracking(-0.5)
                    Text(model.deviceName)
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            // The sentence can outrun the column, so it truncates and carries the whole text as a tooltip.
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.connectedClients.isEmpty ? HostPalette.muted : HostPalette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(HostPalette.raised, in: Capsule())
            .overlay { Capsule().strokeBorder(HostPalette.hairline, lineWidth: 1) }
            .help(statusText)

            // The frame goes on the label, not the button: a bordered button sizes itself to its label.
            Button {
                model.status.isListening ? model.stop() : model.start()
            } label: {
                Text(model.status.isListening ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(HostHostingButtonStyle(isHosting: model.status.isListening))
            .animation(HostMotion.state, value: model.status.isListening)

            Text(verbatim: String(localized: "Port \(model.boundPort) · protocol v\(ProtocolInfo.version)"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(HostPalette.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Detail

}

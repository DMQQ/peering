import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

extension HostStatusView {
    var nowShowingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            previewPane
                .overlay(alignment: .bottomLeading) { previewCaption }
                .clipShape(RoundedRectangle(cornerRadius: HostPalette.panelRadius - 3, style: .continuous))
                .hostPrimaryPanel()
                .overlay {
                    RoundedRectangle(cornerRadius: HostPalette.panelRadius + 3, style: .continuous)
                        .strokeBorder(HostPalette.ink.opacity(heroHovered ? 0.14 : 0), lineWidth: 1)
                }
                .animation(HostMotion.hover, value: heroHovered)
                .onHover { heroHovered = $0 }

            HStack(alignment: .top, spacing: 12) {
                deviceTile
                streamTile
                reachTile
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewCaption: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capturingTitle)
                    .font(HostDisplayFont.display(22))
                    .tracking(-0.3)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: capturingIcon)
                        .font(.system(size: 11, weight: .medium))
                    Text(capturingDetail)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(HostPalette.muted)
            }
            Spacer(minLength: 12)
            if capturingSource != nil {
                HStack(spacing: 6) {
                    Circle()
                        .fill(HostPalette.success)
                        .frame(width: 6, height: 6)
                        .shadow(color: HostPalette.success.opacity(0.6), radius: 4)
                    Text("Live")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(HostPalette.hairline, lineWidth: 1) }
            }
        }
        .foregroundStyle(HostPalette.ink)
        .padding(.horizontal, 18)
        .padding(.top, 36)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Tiles

    private var deviceTile: some View {
        overviewTile(symbol: "iphone", title: String(localized: "Device")) {
            if let client = connectedClient {
                HStack(spacing: 6) {
                    Text(client.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(!client.viaRelay ? "LAN" : model.directPathOpen ? "P2P" : "RELAY")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(HostPalette.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(Capsule().strokeBorder(HostPalette.ink.opacity(0.2)))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Connected for \(client.elapsedDescription(now: context.date))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HostPalette.muted)
                }
            } else {
                Text("Nobody connected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HostPalette.muted)
                Text(model.status.isListening ? "Waiting for a device" : "Press Start to host")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
            }
        }
    }

    private var streamTile: some View {
        let rates = model.resources.rates
        let memory = model.resources.memoryBytes
        return overviewTile(symbol: "gauge.with.dots.needle.50percent", title: String(localized: "Cost to this Mac")) {
            Text(rates.map { String(localized: "\(HostResourceSampler.cpuPercent($0)) CPU") } ?? "Measuring…")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text([
                memory > 0 ? HostResourceSampler.memoryText(memory) : nil,
                rates.map { String(localized: "\(HostResourceSampler.networkText($0.bytesPerSecond)) sent") },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(HostPalette.muted)
                .lineLimit(1)
        }
    }

    private var reachTile: some View {
        let held = model.preventLidCloseSleep && !model.keepAwakeWithheld
        return overviewTile(symbol: held ? "bolt.fill" : "moon.zzz", title: String(localized: "This Mac")) {
            Text(held ? "Kept reachable" : "Sleeps on its own")
                .font(.system(size: 14, weight: .semibold))
            Text(model.keepRunningWithLidClosed ? "Runs with the lid closed" : "Sleeps when the lid closes")
                .font(.caption)
                .foregroundStyle(HostPalette.muted)
                .lineLimit(1)
        }
    }

    private func overviewTile<Content: View>(
        symbol: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HostPalette.muted)
                    .frame(width: 24, height: 24)
                    .background(HostPalette.raised, in: Circle())
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HostPalette.faint)
            }
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous)
                .strokeBorder(HostPalette.litEdge, lineWidth: 1)
        )
    }

    var previewAspect: CGFloat {
        if let preview, preview.height > 0 {
            return CGFloat(preview.width) / CGFloat(preview.height)
        }
        if let screen = NSScreen.screens.first, screen.frame.height > 0 {
            return screen.frame.width / screen.frame.height
        }
        return 16.0 / 10.0
    }

    /// The frame takes the picture shape, capped at 4:3 so a tall window letterboxes instead of forcing a taller frame than the window.
    var previewHeight: CGFloat {
        let panel = max((paneWidth > 0 ? paneWidth : 1000) - Self.paneInset * 2, 320)
        return min(max(panel / previewAspect, 220), panel * 0.75)
    }

    /// The letterbox is black because that is what the phone is sent.
    var previewPane: some View {
        ZStack {
            Color.black

            if !showsPreview {
                // Distinguishes a setting (off) from a state (not streaming).
                VStack(spacing: 7) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 21, weight: .light))
                    Text("Preview off")
                        .font(.caption)
                }
                .foregroundStyle(HostPalette.faint)
            } else if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: capturingSource == nil ? "rectangle.slash" : "ellipsis")
                        .font(.system(size: 21, weight: .light))
                    Text(capturingSource == nil ? "Not streaming" : "Starting…")
                        .font(.caption)
                }
                .foregroundStyle(HostPalette.faint)
            }
        }
        .frame(height: previewHeight)
        .frame(maxWidth: .infinity)
        .animation(HostMotion.state, value: preview == nil)
        // The switch sits on the preview, where the question of whether it is still updating comes up.
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(HostMotion.state) { showsPreview.toggle() }
            } label: {
                Image(systemName: showsPreview ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HostPalette.ink)
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(HostPalette.hairline, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(showsPreview ? "Stop refreshing this preview" : "Show the live preview again")
            .accessibilityLabel(showsPreview ? "Stop the live preview" : "Show the live preview")
        }
        .accessibilityHidden(true)
    }

    var capturingSource: CaptureSource? { model.capturingSource }

    var capturingIcon: String {
        switch capturingSource {
        case .display: return "display"
        case .application: return "macwindow.on.rectangle"
        case .window: return "macwindow"
        case .mosaic: return "rectangle.split.2x2"
        // Not display.slash: it does not exist in SF Symbols and a missing name draws nothing.
        case nil: return "rectangle.slash"
        }
    }

    var capturingTitle: String {
        if let title = model.capturingSourceTitle { return title }
        return model.connectedClients.isEmpty ? String(localized: "Nothing yet") : String(localized: "Choosing a screen…")
    }

    var capturingDetail: String {
        guard let capturingSource else {
            return model.connectedClients.isEmpty
                ? String(localized: "No device is connected.")
                : String(localized: "A device is connected but has not chosen what to show.")
        }
        switch capturingSource {
        case .display: return String(localized: "The whole screen, streaming live.")
        case .application: return String(localized: "One application, streaming live.")
        case .window: return String(localized: "One window, streaming live.")
        case .mosaic(let layout):
            return String(localized: "\(layout.tiles.count) windows, composited live.")
        }
    }

    // MARK: - Devices

}

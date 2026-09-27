import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

/// The live picture, and the shape of its frame.
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

    /// The source's name laid over the foot of the picture, on a scrim so it reads over any desktop.
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
        overviewTile(symbol: "iphone", title: "Device") {
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
        return overviewTile(symbol: "gauge.with.dots.needle.50percent", title: "Cost to this Mac") {
            Text(rates.map { "\(HostResourceSampler.cpuPercent($0)) CPU" } ?? "Measuring…")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text([
                memory > 0 ? HostResourceSampler.memoryText(memory) : nil,
                rates.map { "\(HostResourceSampler.networkText($0.bytesPerSecond)) sent" },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(HostPalette.muted)
                .lineLimit(1)
        }
    }

    private var reachTile: some View {
        let held = model.preventLidCloseSleep && !model.keepAwakeWithheld
        return overviewTile(symbol: held ? "bolt.fill" : "moon.zzz", title: "This Mac") {
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

    /// How tall the picture's frame is: as tall as the pane is wide, in the picture's own shape.
    ///
    /// A band of fixed height was the first thing this was, and it was wrong for the reason any
    /// fixed frame around a variable picture is wrong — a Mac display is wider than it is tall by
    /// half again, so a wide short band left a stripe of black down each side of the picture and a
    /// wide window made the stripe wider instead of the picture larger. The frame takes the
    /// picture's shape, and the picture fills it.
    ///
    /// Capped at 4:3, which is the one place the shape does not win. A single tall window is a
    /// legitimate thing to share, and its shape would otherwise ask for a frame taller than the
    /// window it is in — so past that the picture letterboxes instead, and the layout is not held
    /// hostage by the narrowest thing someone might have picked.
    var previewHeight: CGFloat {
        let panel = max((paneWidth > 0 ? paneWidth : 1000) - Self.paneInset * 2, 320)
        return min(max(panel / previewAspect, 220), panel * 0.75)
    }

    /// The picture itself, in a frame cut to its own shape.
    ///
    /// The letterbox is black because that is what the phone is being sent, so the two show the
    /// same frame — and it should be visible only where the picture genuinely does not fill the
    /// shape, which is the capped case above rather than every case.
    var previewPane: some View {
        ZStack {
            Color.black

            if !showsPreview {
                // Says which of the two reasons this frame is empty, because they mean opposite
                // things: off is a setting, and "not streaming" is a state the user would want
                // to know about.
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
        // The switch is on the thing it switches. It was only in Settings, which is the right
        // place for a setting and the wrong place for a control somebody reaches for while
        // looking at the preview — the picture is where the question "is this still updating"
        // comes up, so it is where the answer goes.
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
        // The same symbol the client's mosaic row wears, so the two ends of one feature look
        // like the same feature.
        case .mosaic: return "rectangle.split.2x2"
        // Not `display.slash`: that symbol does not exist in SF Symbols, and a name that resolves
        // to nothing draws nothing — the chip came out as an empty rounded square, which reads as
        // a rendering fault rather than as a state. `rectangle.slash` is the one that is there.
        case nil: return "rectangle.slash"
        }
    }

    /// The catalogue's name for the source where there is one, and a description of the state
    /// where there is not — a bare display ID would be a worse answer than an honest sentence.
    var capturingTitle: String {
        if let title = model.capturingSourceTitle { return title }
        return model.connectedClients.isEmpty ? "Nothing yet" : "Choosing a screen…"
    }

    var capturingDetail: String {
        guard let capturingSource else {
            return model.connectedClients.isEmpty
                ? "No device is connected."
                : "A device is connected but has not chosen what to show."
        }
        switch capturingSource {
        case .display: return "The whole screen, streaming live."
        case .application: return "One application, streaming live."
        case .window: return "One window, streaming live."
        case .mosaic(let layout):
            // The count, because it is the one number that says how much work this window is
            // asking of the Mac: every tile is a ScreenCaptureKit stream of its own.
            return "\(layout.tiles.count) windows, composited live."
        }
    }

    // MARK: - Devices

    /// On a wide window the compact device list sits beside the longer activity feed, making
    /// the overview an intentionally uneven dashboard. At the minimum window width it falls
    /// back to the familiar vertical reading order.
}

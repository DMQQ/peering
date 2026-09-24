import AppKit
import RemoteCore
import SwiftUI

/// The live picture, and the shape of its frame.
///
/// An extension on the window rather than a type of its own — the state is the
/// window's, and the window is easier to read in pieces than as one file of
/// fifteen hundred lines.
extension HostStatusView {
    /// What the connected device is looking at.
    ///
    /// First in the window, because it is the question this app exists to answer for whoever is
    /// sitting at the Mac. Everything else — who is attached, whether a permission is granted —
    /// is context for this one fact.
    var nowShowingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No eyebrow. "LIVE SESSION" sat above this title in tracked capitals and said what
            // the green pill in the sidebar and the green pill in the footer below already said —
            // but the cost was not the repetition, it was the shape: a small tracked caption over
            // a larger line is the skeleton every generated dashboard wears, and it made a window
            // with real information in it look like a mock-up. The title carries itself.
            //
            // The state it was announcing is on the right, where it is worth more: a dot beside
            // the name of the device that is actually connected. A dot that is only there when
            // something is live says more than a label that changes one word.
            HStack(alignment: .center, spacing: 14) {
                Text(capturingTitle)
                    .font(HostDisplayFont.display(21))
                    .tracking(-0.3)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let client = connectedClient {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(HostPalette.success)
                                .frame(width: 6, height: 6)
                                .shadow(color: HostPalette.success.opacity(0.6), radius: 4)
                            Text(client.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(client.elapsedDescription())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HostPalette.muted)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 13)

            VStack(spacing: 0) {
                previewPane

                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(capturingSource == nil ? HostPalette.raised : HostPalette.ink.opacity(0.12))
                        Image(systemName: capturingIcon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(capturingSource == nil ? HostPalette.faint : HostPalette.ink)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(capturingDetail)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HostPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    if capturingSource != nil {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(HostPalette.success)
                                .frame(width: 6, height: 6)
                                .shadow(color: HostPalette.success.opacity(0.6), radius: 4)
                            Text("Live")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(HostPalette.ink)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(HostPalette.raised, in: Capsule())
                        .overlay { Capsule().strokeBorder(HostPalette.hairline, lineWidth: 1) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(HostPalette.surface)
            }
            // Concentric with the bezel outside it — the panel's radius less the panel's own
            // padding. Two radii that are close but not equal is the thing that reads as sloppy
            // without anyone being able to say why.
            .clipShape(RoundedRectangle(cornerRadius: HostPalette.panelRadius - 3, style: .continuous))
        }
        .hostPrimaryPanel()
        // The pointer's arrival used to scale this panel by two points in a thousand, which is
        // not something anybody can see and was something everybody paid for: `scaleEffect` sits
        // *outside* `hostPrimaryPanel`, so the panel's 28-point shadow was inside the animated
        // content and had to be blurred again on every frame of the spring, for a movement of two
        // points on a pane this wide. The bezel lighting up is the same acknowledgement for the
        // price of one stroke, and a one-point stroke does not blur.
        .overlay {
            RoundedRectangle(cornerRadius: HostPalette.panelRadius + 3, style: .continuous)
                .strokeBorder(HostPalette.ink.opacity(heroHovered ? 0.14 : 0), lineWidth: 1)
        }
        .animation(HostMotion.hover, value: heroHovered)
        .onHover { heroHovered = $0 }
    }

    /// The shape the frame should be.
    ///
    /// Whatever is actually being sent, and the display when nothing is — which is also what a
    /// connection captures until the client asks for something else, so the frame does not change
    /// shape the moment a stream starts.
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

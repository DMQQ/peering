import AppKit
import RemoteCore
import SwiftUI

/// The rail of sections, and what sits above it.
extension HostStatusView {
    /// The rail of sections, drawn here rather than handed to a sidebar `List`.
    ///
    /// A source-list `List` looks like the natural thing for five rows and was the first thing
    /// this window used, and it has one behaviour that cannot be argued with: it paints every row's
    /// symbol with the accent colour, and setting a `foregroundStyle` on the `Label` does not stop
    /// it. Five blue glyphs under one blue selection is the whole window's worth of accent spent
    /// before anything has happened, and the colour stops meaning "you are here" when it is also
    /// what the row below it means, and the row below that.
    ///
    /// So the rows are buttons. What that gives up is the arrow-key walking a source list does for
    /// free; what it buys is the ink staying ink, a selection that is a shape we chose, and
    /// ⌘1–⌘5 — which is a shorter path to any of these panes than arrowing to it ever was.
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
            Spacer(minLength: 0)
        }
        .background(HostPalette.backdrop)
    }

    /// One section. Selection is a fill rather than a tint, which is what the phone's rail does
    /// and the reason it does it: at arm's length a coloured glyph is hard to find, and a coloured
    /// shape is not.
    /// One section. Selection is a fill rather than a tint, which is what the phone's rail does
    /// and the reason it does it: at arm's length a coloured glyph is hard to find, and a coloured
    /// shape is not.
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

    /// The one part of the window that is visible whatever pane is showing.
    ///
    /// The app's own icon rather than an SF Symbol: this is the thing in the Dock, and matching
    /// it is what makes the window read as *this app* rather than as a settings panel that
    /// happens to have a status line. The state is carried by the sentence below it, which is
    /// the part a symbol cannot say.
    /// The one part of the window that is visible whatever pane is showing.
    ///
    /// The app's own icon rather than an SF Symbol: this is the thing in the Dock, and matching
    /// it is what makes the window read as *this app* rather than as a settings panel that
    /// happens to have a status line. The state is carried by the sentence below it, which is
    /// the part a symbol cannot say.
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

            // The sentence can outrun the column — "Connected — Damian's iPhone" is most of it
            // — so it truncates and carries the whole thing as a tooltip.
            //
            // One fact, said once. This was a coloured dot, coloured text, a tinted fill and a
            // tinted border, which is four marks for a state that has one value; at that point
            // the colour stops meaning anything and the pill just looks loud. The dot carries the
            // state, the sentence stays legible ink, and the pill itself is only a shape.
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

            // The frame goes on the label, not the button. A bordered button sizes itself to
            // its label, so widening the button only pads the space around it — the control
            // stays the size of the word and sits in the middle of the column.
            //
            // Big, and it is the only filled control in the app. Both are deliberate. This is
            // the one thing the whole window exists to offer, and it used to be a small grey
            // word in the middle of a column — the least prominent thing on a screen whose only
            // question is whether the Mac is being shared. Everything else here is ink on a
            // surface and stays that way; this is the exception that earns its fill.
            //
            // The same blue the phone uses for the one control it marks, rather than the Mac's
            // own highlight colour, so the two apps agree about what "press this" looks like.
            // Quiet when it stops: the two states are not equals, and one of them is how you
            // put it down — see `HostHostingButtonStyle`.
            Button {
                model.status.isListening ? model.stop() : model.start()
            } label: {
                Text(model.status.isListening ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(HostHostingButtonStyle(isHosting: model.status.isListening))
            .animation(HostMotion.state, value: model.status.isListening)

            Text("Port \(model.boundPort) · protocol v\(ProtocolInfo.version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(HostPalette.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Detail

}

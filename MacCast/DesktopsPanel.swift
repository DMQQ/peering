import RemoteCore
import SwiftUI
import UIKit

/// The desktops of every screen, as pictures.
///
/// Pictures rather than a list of numbers because the question being asked is "which one had my
/// browser on it", and a number cannot answer that. Each tile is a snapshot taken when that
/// desktop was last active — see ``SpacePreview`` for why it cannot be live.
///
/// One row per screen. Spaces are per-display, so a single flat strip of five tiles would be five
/// unlabelled pictures two of which are called "Desktop 1" — the grouping is the answer to which
/// screen a tile belongs to, and the chip is the label for it. The chip only appears when there is
/// more than one screen to tell apart.
struct DesktopsPanel: View {
    @Environment(SessionModel.self) private var model

    /// Reported so the gesture surface knows a touch on the panel belongs to the panel and not to
    /// the Mac underneath it.
    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// Called once the user has picked a desktop, so the caller can put the panel away. What
    /// "away" means is the caller's business — see the setting it consults.
    var onSelect: () -> Void = {}

    /// Whether the panel is worth offering at all.
    ///
    /// More than one desktop, **or** more than one screen. A second screen qualifies on its own
    /// even with a single desktop on it, because tapping that desktop is how the picture is moved
    /// to it — a control that can only ever do nothing is clutter, and this one can do something.
    static func showsDesktops(_ info: SpaceInfo) -> Bool {
        info.totalCount > 1 || info.displays.count > 1
    }

    @ViewBuilder
    var body: some View {
        if let info = model.catalog?.spaceInfo, Self.showsDesktops(info) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Desktops")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // Scrolls when it has to, which is what keeps a third screen or a fourth from
                // pushing the first row off the top of the panel and out of reach.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(info.displays) { display in
                            VStack(alignment: .leading, spacing: 6) {
                                if info.displays.count > 1 {
                                    chip(for: display)
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        // Offsets rather than `1...count`, which is an empty range
                                        // when a display reports nothing and traps on the way.
                                        ForEach(0..<display.count, id: \.self) { offset in
                                            tile(
                                                display: display,
                                                index: offset + 1,
                                                showsScreenName: info.displays.count > 1
                                            )
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 10)
            .reportChromeFrame(.panel, into: $chromeFrames)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// A screen's name, on its own line above that screen's desktops.
    ///
    /// Above rather than beside, and hugging its text rather than given a width. Display names are
    /// arbitrary user-facing strings — "Built-in Retina Display" is a normal one and a phone panel
    /// is narrow — so sitting beside the tiles would mean a fixed width, and a fixed width would
    /// mean truncating real names to fit around a thumbnail. Given the whole row's width there is
    /// nothing to truncate. Each row still starts at the same left edge, which is what keeps the
    /// panel reading as rows rather than as a ragged list.
    ///
    /// The name is read from the catalogue rather than sent alongside the desktops: it is the same
    /// `NSScreen.localizedName` the source picker shows, so the two can never describe one screen
    /// two ways.
    private func chip(for display: SpaceDisplay) -> some View {
        Text(name(of: display))
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(ColorPalette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ColorPalette.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(ColorPalette.ink.opacity(0.15))
            }
    }

    private func name(of display: SpaceDisplay) -> String {
        model.catalog?.descriptor(for: .display(display.displayID))?.title ?? "Display"
    }

    private func tile(display: SpaceDisplay, index: Int, showsScreenName: Bool) -> some View {
        let isCurrent = index == display.current
        let label = "Desktop \(index)\(isCurrent ? ", current" : "")"
        return Button {
            switchToDesktop(display: display, index: index)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ColorPalette.surface)

                    if let data = display.preview(for: index)?.jpegData,
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // An empty tile is the truth: this desktop has not been on screen since
                        // the host started, so there is no picture of it to show. A placeholder
                        // image would be a picture of a desktop that does not exist.
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 104, height: 65)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isCurrent ? ColorPalette.accent : ColorPalette.ink.opacity(0.18),
                            lineWidth: isCurrent ? 2 : 1
                        )
                }

                Text("Desktop \(index)")
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? ColorPalette.accent : Color.secondary)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(showsScreenName ? "\(name(of: display)) \(label)" : label)
    }

    /// Reveals a desktop, and takes the picture with it. Always both.
    ///
    /// A desktop tile names a *screen* as well as a desktop, so tapping one is a statement about
    /// where to look. Switching only the Space left the user watching one screen while another
    /// rearranged itself off-camera — and when the source was a window rather than a display,
    /// which follows its window wherever that window is, nothing visible happened at all.
    ///
    /// This used to insist the current source be a display first, on the theory that a user
    /// watching one window had asked to watch *that*. That was the wrong call: the tap is a
    /// destination, and refusing to go there is what made the tiles look broken.
    ///
    /// The Space goes out first so the move reads as one thing. The Mac rearranges the desktop
    /// that was asked for while the picture is still where it was, and the picture then arrives on
    /// it already showing the right thing; the other order shows the screen being left, and then a
    /// second jump.
    private func switchToDesktop(display: SpaceDisplay, index: Int) {
        model.send(.switchToSpace(display: display.displayID, index: index))

        let source = CaptureSource.display(display.displayID)
        if model.activeSourceID != source.stableID {
            model.send(.setCaptureSource(source))
        }
        // Even when no source change was needed: the tap was still a choice, and the panel gets
        // out of the way for all of them or none.
        onSelect()
    }
}

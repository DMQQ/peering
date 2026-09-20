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

    /// How tall the panel may grow. Passed in rather than assumed, because the tiles are sized
    /// against it — see ``tileSize(count:rows:showsChips:)``.
    var maximumHeight: CGFloat = .infinity

    /// The width the tiles have to work with, given by the panel that contains this one.
    ///
    /// Worked out by the caller rather than measured here, and that is a correction: measuring it
    /// from inside made the number depend on the thing it was sizing. The rows are horizontal
    /// scroll views, which take whatever they are offered, so the width they reported was the
    /// width they had been given — which came from the tiles, which were sized from it. It settled
    /// on the starting value and stayed there, which is why the tiles never grew.
    var contentWidth: CGFloat = 0

    /// The smallest a tile may be. Below this the thumbnail stops being a picture of anything and
    /// the caption under it stops fitting.
    private static let minimumTile = CGSize(width: 104, height: 65)
    /// The largest, so two desktops do not become two enormous pictures. Generous, because the
    /// point of the exercise is that a screen with two desktops should not leave most of its panel
    /// empty — and the height ceiling below is the limit that actually binds on a phone held
    /// sideways, so this one only has to stop the absurd case.
    private static let maximumTileWidth: CGFloat = 260
    /// Width over height, held constant so a tile keeps the shape of a screen rather than the
    /// shape of whatever room it was given.
    private static let tileAspect = 65.0 / 104.0

    private static let tileGap: CGFloat = 8
    private static let rowGap: CGFloat = 12
    private static let rowInnerGap: CGFloat = 5
    private static let captionHeight: CGFloat = 13
    private static let chipHeight: CGFloat = 21
    private static let headingHeight: CGFloat = 22
    private static let panelInset: CGFloat = 10
    /// The margin around the glass card, on the sides only.
    private static let panelMargin: CGFloat = 10

    /// What the panel's own insets take off the width its tiles are laid out in.
    ///
    /// **Exposed because the caller has to know it, and did not.** The width handed in is the
    /// width the panel is *given*; the tiles get that much less the card's padding and the
    /// margin outside it, on both sides. Leaving the margin out went unnoticed for as long as
    /// the row scrolled sideways — an overestimate was absorbed by the scroll view and looked
    /// like nothing at all. A grid does not scroll, so the same overestimate is a second column
    /// hanging off the edge of the screen, which is exactly what it did.
    static let horizontalInset: CGFloat = (panelInset + panelMargin) * 2

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
                    VStack(alignment: .leading, spacing: Self.rowGap) {
                        ForEach(info.displays) { display in
                            let laying = layout(desktops: display.count, displays: info.displays.count)
                            VStack(alignment: .leading, spacing: 6) {
                                if info.displays.count > 1 {
                                    chip(for: display)
                                }
                                if laying.grid {
                                    LazyVGrid(
                                        columns: Array(
                                            repeating: GridItem(
                                                .fixed(laying.tile.width),
                                                spacing: Self.tileGap
                                            ),
                                            count: laying.columns
                                        ),
                                        alignment: .leading,
                                        spacing: Self.tileGap
                                    ) {
                                        tiles(of: display, acrossScreens: false, size: laying.tile)
                                    }
                                    .padding(.vertical, 2)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: Self.tileGap) {
                                            tiles(of: display, acrossScreens: true, size: laying.tile)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Self.panelInset)
            .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, Self.panelMargin)
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
    /// The name of a display, marked when the video is showing that screen.
    ///
    /// A Mac with two screens shows two rows here and each row correctly has a current desktop
    /// of its own, so two highlighted tiles is the honest answer and not a fault. What was
    /// missing is the other fact: *which* of those two screens the picture on the phone is
    /// actually of. Without it a capture source that had got stuck elsewhere read as a panel
    /// that had stopped working, because both rows looked equally plausible.
    ///
    /// Filled rather than tinted, because that is what this app already means by "this one is
    /// on" — see ``ColorPalette/selectedFill``, and the same mark on the sources list. A bare
    /// checkmark rather than the circled one used there: that one sits on a dark row and needs
    /// the disc to carry it, while this sits on the fill itself.
    private func chip(for display: SpaceDisplay) -> some View {
        let isShowing = model.activeSourceID == CaptureSource.display(display.displayID).stableID

        return HStack(spacing: 4) {
            if isShowing {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(name(of: display))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ColorPalette.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isShowing ? ColorPalette.selectedFill : ColorPalette.surface, in: Capsule())
        .overlay {
            // The hairline is what gives the resting chip a body. On the filled one it is the
            // fill doing that, and a border would only dull the accent.
            Capsule().strokeBorder(ColorPalette.ink.opacity(isShowing ? 0 : 0.15))
        }
        .animation(Motion.tap, value: isShowing)
    }

    private func name(of display: SpaceDisplay) -> String {
        model.catalog?.descriptor(for: .display(display.displayID))?.title ?? "Display"
    }

    /// The shape a screen's desktops are laid out in: whether it is a grid, how many go across,
    /// how many rows that makes, and how big a tile comes out.
    ///
    /// **One screen is a grid; several are a row each.** With two or more screens the row-per-screen
    /// layout is carrying information — it is what says which desktops belong to which screen, and
    /// the chip above each row is read against it. With one screen there is nothing left to group,
    /// and a single horizontal row leaves the panel exactly one tile tall and as empty as the phone
    /// is wide.
    private func layout(
        desktops count: Int, displays: Int
    ) -> (grid: Bool, columns: Int, rows: Int, tile: CGSize) {
        guard displays == 1 else {
            return (
                grid: false,
                columns: max(count, 1),
                rows: displays,
                tile: tileSize(columns: max(count, 1), rows: displays, showsChips: true)
            )
        }
        return gridLayout(count: count)
    }

    /// The grid one screen's desktops take, and the size of a tile in it.
    ///
    /// The column count starts at the square root — the arrangement that keeps a grid as close to
    /// square as whole tiles allow, so three desktops are two rows of two with one gap, four are a
    /// true 2×2, and six are two rows of three. Two stay side by side, because a pair already has
    /// the shape a grid would give it.
    ///
    /// Then it works *down*, and that is the part worth explaining. When the panel is short — a
    /// phone held sideways, which is where ``maximumHeight`` bites — the height budget squeezes the
    /// tiles to ``minimumTile``, and a row of them no longer reaches across the panel. What that
    /// looks like is a column missing, which reads as a mistake rather than as a shortage. Dropping
    /// a column makes the remaining tiles wider and the row full again; at one column it is the
    /// plain single row this used to be, which is the right answer when there is no room.
    private func gridLayout(count: Int) -> (grid: Bool, columns: Int, rows: Int, tile: CGSize) {
        guard count > 0 else { return (grid: true, columns: 1, rows: 1, tile: Self.minimumTile) }

        var columns = max(1, Int(ceil(Double(count).squareRoot())))
        while true {
            let rows = (count + columns - 1) / columns
            let tile = tileSize(columns: columns, rows: rows, showsChips: false)
            if columns == 1 || tile.width > Self.minimumTile.width {
                return (grid: true, columns: columns, rows: rows, tile: tile)
            }
            columns -= 1
        }
    }

    /// One screen's tiles, for whichever of the two layouts is putting them up.
    ///
    /// Offsets rather than `1...count`, which is an empty range when a display reports nothing and
    /// traps on the way.
    @ViewBuilder
    private func tiles(of display: SpaceDisplay, acrossScreens: Bool, size: CGSize) -> some View {
        ForEach(0..<display.count, id: \.self) { offset in
            tile(
                display: display,
                index: offset + 1,
                showsScreenName: acrossScreens,
                size: size
            )
        }
    }

    /// The size of one tile, given how many go across its row and how many rows share the height.
    ///
    /// Grown to fill the width when a screen has only two or three desktops — a pair of thumbnails
    /// pinned at 104 points leaves most of the panel empty, which is the whole of "make them fill
    /// the window" — and held back by the height the panel actually has, so filling the width
    /// cannot cost the row below it its place. One fixed size cannot do both: it is too big for a
    /// short landscape panel and too small for a tall portrait one.
    private func tileSize(columns: Int, rows: Int, showsChips: Bool) -> CGSize {
        guard columns > 0 else { return Self.minimumTile }

        let gaps = CGFloat(columns - 1) * Self.tileGap
        var width = contentWidth > 0 ? (contentWidth - gaps) / CGFloat(columns) : Self.minimumTile.width

        if maximumHeight.isFinite, rows > 0 {
            let rowOverhead = Self.captionHeight + Self.rowInnerGap
                + (showsChips ? Self.chipHeight + 6 : 0)
            let overhead = Self.headingHeight
                + Self.panelInset * 2
                + CGFloat(rows - 1) * Self.rowGap
                + CGFloat(rows) * rowOverhead
            let roomPerRow = max(maximumHeight - overhead, 0) / CGFloat(rows)
            width = min(width, roomPerRow / Self.tileAspect)
        }

        let clamped = min(max(width, Self.minimumTile.width), Self.maximumTileWidth)
        return CGSize(width: clamped.rounded(), height: (clamped * Self.tileAspect).rounded())
    }

    private func tile(
        display: SpaceDisplay,
        index: Int,
        showsScreenName: Bool,
        size: CGSize
    ) -> some View {
        // Two facts, two weights, because they are different things and the panel is useless
        // without both.
        //
        // `isCurrent` is where *that screen* is — every display has one and they are all true
        // at once, which is what made marking them identically look like two answers to one
        // question. `isLive` is where the phone is looking, and exactly one desktop can be it.
        //
        // Suppressing the first to fix the second was a worse trade: the row for the display
        // you are not watching then showed nothing about where it was, so tapping "desktop 2"
        // on a screen already showing desktop 2 became a coin toss. It is not a no-op a user
        // can see — the panel closes, the picture does not move, and it reads as broken.
        let isShowing = model.activeSourceID == CaptureSource.display(display.displayID).stableID
        let isCurrent = index == display.current
        let isLive = isShowing && isCurrent
        let label = "Desktop \(index)\(isLive ? ", showing" : isCurrent ? ", current" : "")"
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
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isLive
                                ? ColorPalette.accent
                                : (isCurrent ? ColorPalette.ink.opacity(0.5) : ColorPalette.ink.opacity(0.18)),
                            lineWidth: isLive ? 2 : (isCurrent ? 1.5 : 1)
                        )
                }

                Text(isLive ? "Desktop \(index) · here" : "Desktop \(index)")
                    .font(.system(size: 10, weight: isLive ? .semibold : .regular))
                    .foregroundStyle(
                        isLive
                            ? ColorPalette.accent
                            : (isCurrent ? ColorPalette.ink : Color.secondary)
                    )
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
            // Through the model rather than `send`, so the choice is recorded as well as made.
            // This is what went wrong: the raw send moved the host without moving
            // `activeSourceID`, so the next tap back to a display already named there looked
            // like no move at all and sent nothing.
            model.selectSource(source)
        }
        // Even when no source change was needed: the tap was still a choice, and the panel gets
        // out of the way for all of them or none.
        onSelect()
    }
}

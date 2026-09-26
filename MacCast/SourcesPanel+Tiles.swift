import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// What a tile has to draw about its source: whether it is marked, and where it sits in an
    /// arrangement being built.
    ///
    /// **One mark per mode, never two.** In the ordinary pick the accent says which source the
    /// phone is showing, which is what ``desktopTile(_:index:showsScreenName:)`` means by it too.
    /// In the accumulating one the same accent says which tiles have been picked, and the badge
    /// says where each of them landed — the arrangement is filled in reading order, so that number is the tile's place in
    /// the finished picture. Both at once would be one mark meaning two things.
    func placement(
        of descriptor: CaptureSourceDescriptor
    ) -> (marked: Bool, isLive: Bool, place: Int?) {
        let isLive = !buildingMosaic && descriptor.id == model.activeSourceID
        let place = buildingMosaic
            ? picked.firstIndex { $0.source == descriptor.source }.map { $0 + 1 }
            : nil
        return (isLive || place != nil, isLive, place)
    }

    func choose(_ descriptor: CaptureSourceDescriptor) {
        if buildingMosaic {
            // `morph` rather than `tap`, because a pick is a control gaining something rather
            // than one changing state: the badge has to arrive with enough give to be seen
            // arriving, or picking a fifth window is a tap with no answer. See ``placeBadge``.
            withAnimation(Motion.morph) { toggle(descriptor) }
        } else {
            // Animated because of the one case where this leaves a standing mosaic: the tile
            // borders drawn over the picture fade out as the arrangement is given up, and that
            // fade belongs to the tap that caused it.
            withAnimation(Motion.settle) { model.selectSource(descriptor) }
            onSelect()
        }
    }

    /// The tile's place in the arrangement being built, springing in as it is picked.
    ///
    /// **The badge is the selection's only movement, and that is deliberate.** The accent edge
    /// changes colour under `Motion.tap` and says which tiles are in; this says *where* each of
    /// them landed, and it is the one thing that appears where nothing was. A tile that slid or
    /// scaled would be moving in a grid the user is still choosing from, so the number is what
    /// arrives — over `Motion.morph`, the app's curve for a control that changes shape rather
    /// than one that changes state.
    @ViewBuilder
    func placeBadge(_ place: Int?) -> some View {
        if let place {
            Text("\(place)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(ColorPalette.onInk)
                .frame(width: 18, height: 18)
                .background(ColorPalette.accent, in: Circle())
                .padding(5)
                .transition(Self.badge)
        }
    }

    /// How a place badge arrives and leaves: from nothing, with a little give.
    ///
    /// One definition for the two grids, so a number cannot appear one way on a window and
    /// another way on a heading.
    static let badge = AnyTransition.scale(scale: 0.4).combined(with: .opacity)

    func caption(
        _ descriptor: CaptureSourceDescriptor,
        isLive: Bool,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(descriptor.title)
                .font(.system(size: 10, weight: isLive ? .semibold : .regular))
                .foregroundStyle(isLive ? ColorPalette.accent : ColorPalette.ink)
                .lineLimit(1)
            if let subtitle = descriptor.subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    /// How wide a tile's title may be: the width of the picture, which is the box's height times
    /// the picture's shape.
    ///
    /// The box is the cell wide and ``tileAspect`` tall, so a picture that is narrower than that
    /// shape is drawn narrower than the box, and its name has to be told by how much. A picture
    /// wider than the box is the cell wide and gets the cell's width, which is what the `min` says.
    func captionWidth(shape: CGFloat) -> CGFloat {
        guard tileCellWidth > 0, Self.tileAspect > 0 else { return .infinity }
        return min(tileCellWidth, tileCellWidth / Self.tileAspect * shape)
    }

    func spoken(_ descriptor: CaptureSourceDescriptor) -> String {
        [descriptor.title, descriptor.subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// The grids' own numbers.
    ///
    /// **Pictures and icons are two grids rather than one with two skins.** A picture wants a wide
    /// tile and as much of the panel as it can have; an icon is square, smaller, and wants its
    /// neighbours close, because a grid of icons is read as one shape at a glance.
    ///
    /// Adaptive rather than a fixed count: the panel is a fixed fraction of a phone, but the
    /// phones are not all the same width, and a count that suits one leaves a second column
    /// hanging off the edge of another. **That happened**, in the desktops grid this section
    /// replaced: it sized its tiles off a width worked out by its caller, the caller left the
    /// margin outside the glass card out of that number, and the tiles hung off the screen. An
    /// adaptive grid cannot make that mistake, because the width it divides is the width it is
    /// actually drawn in.
    static var previewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: tileGap)]
    }

    static var iconColumns: [GridItem] {
        [GridItem(.adaptive(minimum: iconMinimumWidth), spacing: iconGap)]
    }

    /// The width a picture tile asks for. Adaptive columns give every cell at least this much and
    /// then share out what is left, so this is the floor a tile can come out at rather than a size
    /// it is given.
    ///
    /// **Raised by half**, because at a hundred and four the pictures were small enough that a
    /// window's contents could not be told from the same few greys of another, which is the whole
    /// reason this panel shows pictures instead of a list of names. Widening the floor costs
    /// columns on a narrow phone, which is the trade being made on purpose.
    static let tileMinimumWidth: CGFloat = 156
    static let tileGap: CGFloat = 8

    /// The shape a tile is drawn at when there is no size to take one from: a source the Mac has
    /// reported nothing about. Every other tile is its own picture's shape. See ``tileShape(_:)``.
    static let tileAspect: CGFloat = 16.0 / 10.0

    /// The box a tile is drawn inside: as wide as its cell, and no taller than a 16:10 tile.
    ///
    /// **Invisible, and only ever a bound.** The picture inside takes its own shape, as large as
    /// this allows and no larger, so a portrait window comes out as a narrow tile rather than a
    /// tall one and a wide one fills the width without being stretched. It is also what makes a
    /// row of differently shaped tiles a row: every tile is measured against the same box rather
    /// than against its neighbours, so the names under them stay on one line.
    static func tileBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(tileAspect, contentMode: .fit)
            .overlay(alignment: .topLeading) { content() }
    }

    /// The two ends ``tileShape(_:)`` holds a shape between.
    ///
    /// **Not every shape a size can have is one a tile should be drawn at.** The box bounds how
    /// tall a tile may be, so an extreme shape does not overflow anything, it is a sliver: a window
    /// a few points wide would be a few points wide here, with its name under it. These two lie
    /// outside every shape that turns up in practice, a phone's window being about 0.47 and an
    /// ultrawide monitor about 2.3, so all they cost is a source at one extreme being drawn very
    /// slightly cropped.
    static let tileShapeBounds: ClosedRange<CGFloat> = 0.4...2.5

    /// The shape a tile for this source is drawn at: the picture's own.
    ///
    /// The thumbnail is asked first because it is the thing that gets drawn, and a box that
    /// disagrees with its picture is a box with something cropped off it. A source with no picture
    /// yet falls back to the size the Mac reports, which is that picture's shape, so a tile does
    /// not change shape when the picture lands.
    static func tileShape(for descriptor: CaptureSourceDescriptor) -> CGFloat {
        guard let thumbnail = descriptor.thumbnail else { return tileShape(descriptor.pixelSize) }
        return tileShape(CGSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
    }

    /// One desktop's tile shape: that desktop's own picture, or the screen's shape without one.
    ///
    /// The second half is what keeps a desktop tile from resizing when its photograph is taken,
    /// and every desktop of a screen shares a shape, so the row is one shape rather than several.
    func desktopShape(_ display: SpaceDisplay, index: Int) -> CGFloat {
        guard let preview = display.preview(for: index) else {
            let size = model.catalog?.descriptor(for: .display(display.displayID))?.pixelSize ?? .zero
            return Self.tileShape(size)
        }
        return Self.tileShape(CGSize(width: CGFloat(preview.width), height: CGFloat(preview.height)))
    }

    /// A size's shape, held between the two ends a tile is drawn at.
    ///
    /// **A window is whatever shape the user left it, which is not a promise about anything.** A
    /// size with nothing in it keeps the panel's own 16:10, and a shape past the bounds is drawn
    /// at the bound, which crops the picture by that same small amount. See ``tileShapeBounds``.
    static func tileShape(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return tileAspect }
        return min(
            max(size.width / size.height, Self.tileShapeBounds.lowerBound),
            Self.tileShapeBounds.upperBound
        )
    }

    /// How much bigger a tile gets when it becomes the picture.
    ///
    /// A quarter of the gutter either side, so a tile that grows into the gap reads as arriving
    /// rather than as a grid that has gone ragged. What it costs the panel is in ``tileRoom``.
    static let tileGrowth: CGFloat = 1.045

    /// The room the panel leaves inside its edges for a tile that has grown.
    ///
    /// **A scaled tile is wider than the cell it sits in, and a scroll view clips at its own
    /// bounds.** Half of ``tileGrowth`` comes off each side, and on the widest phone a grid of two
    /// columns gives a tile about 190 points, so it grows 4.3 points each way; six leaves that a
    /// little to spare. Without it the first and last tile of every row lost the ends of their
    /// border, which is a ring cut open rather than the mark of the one being watched.
    static let tileRoom: CGFloat = 6

    /// The size of a Home Screen icon, which is what this grid is quoting.
    ///
    /// **Close to the width of a column, and that is the number that matters.** An adaptive grid
    /// gives every cell at least ``iconMinimumWidth`` and then spreads the leftover width evenly
    /// between them, so a small icon in a wide cell is not a small icon — it is the same icon with
    /// a gutter either side of it, and a row of those reads as a grid with something missing
    /// rather than as a grid. 74 in a cell that comes out around 86 leaves the few points a
    /// Home Screen leaves and no more.
    static let iconSize: CGFloat = 74
    /// The corner `ApplicationIcon` derives from ``iconSize``, needed here for the mark behind it.
    static let iconCorner: CGFloat = iconSize * (11.0 / 42.0)
    /// Just the icon and its gutter. Anything more and the grid spends its leftover width on gaps
    /// it does not need, which is exactly the state this number is here to prevent.
    static let iconMinimumWidth: CGFloat = iconSize + 8
    static let iconGap: CGFloat = 8

    /// Adds or removes one source from the arrangement being built.
    ///
    /// The cap is enforced here rather than by greying rows out: a row that cannot be added is
    /// a row that looks broken, and the honest answer to "why not" is that the Mac is already
    /// capturing as many as it will. Picking past it replaces nothing, it simply does not add.
    func toggle(_ descriptor: CaptureSourceDescriptor) {
        if let index = picked.firstIndex(where: { $0.source == descriptor.source }) {
            picked.remove(at: index)
        } else if picked.count < MosaicLayout.maximumTileCount {
            picked.append(descriptor)
        }
    }

    var filteredInstalled: [InstalledApplicationDescriptor] {
        let applications = model.catalog?.installedApplicationsNotRunning ?? []
        guard !query.isEmpty else { return applications }
        return applications.filter { $0.title.localizedStandardContains(query) }
    }

    func filtered(_ sources: [CaptureSourceDescriptor]) -> [CaptureSourceDescriptor] {
        guard !query.isEmpty else { return sources }
        return sources.filter {
            $0.title.localizedStandardContains(query)
                || ($0.subtitle?.localizedStandardContains(query) ?? false)
        }
    }
}

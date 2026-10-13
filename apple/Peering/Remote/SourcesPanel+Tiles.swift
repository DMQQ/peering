import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// One mark per mode, never two: in the ordinary pick the accent says which source is shown; accumulating, it says which are picked and the badge says where each landed (reading order).
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
            // `morph` rather than `tap`: a pick is a control gaining something, and the badge needs give to be seen arriving.
            withAnimation(Motion.morph) { toggle(descriptor) }
        } else {
            // Animated because the tile borders over a standing mosaic fade out as the arrangement is given up, and that fade belongs to the tap.
            withAnimation(Motion.settle) { model.selectSource(descriptor) }
            onSelect()
        }
    }

    /// The badge is the selection's only movement: a sliding or scaling tile would move in a grid still being chosen from.
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

    /// One definition for the two grids, so a number cannot appear one way on a window and another on a heading.
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

    /// The box is the cell wide and `tileAspect` tall, so a narrower picture is drawn narrower and its name must be told by how much.
    func captionWidth(shape: CGFloat) -> CGFloat {
        guard tileCellWidth > 0, Self.tileAspect > 0 else { return .infinity }
        return min(tileCellWidth, tileCellWidth / Self.tileAspect * shape)
    }

    func spoken(_ descriptor: CaptureSourceDescriptor) -> String {
        [descriptor.title, descriptor.subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// Pictures and icons are two grids: a picture wants a wide tile, an icon is square and wants close neighbours.
    /// Adaptive rather than a fixed count: a count that suits one phone leaves a column hanging off another. That happened in the desktops grid this replaced, which sized tiles from a caller-computed width that omitted the margin outside the glass card.
    static var iconColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: iconGap, alignment: .top), count: 5)
    }

    /// The floor adaptive columns give each cell, not a size.
    /// Raised by half: at 104 a window's contents could not be told from another's greys, which is the reason the panel shows pictures.
    static let tileMinimumWidth: CGFloat = 156
    static let tileGap: CGFloat = 8

    /// The shape for a source the Mac reported nothing about.
    static let tileAspect: CGFloat = 16.0 / 10.0

    /// Invisible, only a bound: the picture takes its own shape as large as this allows, and every tile measured against the same box keeps the names on one line.
    /// Given a height, the box is exactly the picture, for rows that pack by their own widths.
    @ViewBuilder
    static func tileBox<Content: View>(
        height: CGFloat? = nil, shape: CGFloat = tileAspect, @ViewBuilder content: () -> Content
    ) -> some View {
        if let height {
            content().frame(width: height * shape, height: height)
        } else {
            Color.clear
                .aspectRatio(tileAspect, contentMode: .fit)
                .overlay(alignment: .topLeading) { content() }
        }
    }

    static func tileRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: tileGap) { content() }
                .padding(tileRoom)
        }
        .scrollIndicators(.hidden)
        .padding(-tileRoom)
    }

    static let packedTileHeight: CGFloat = tileMinimumWidth / tileAspect

    /// Not every shape is one a tile should be drawn at: an extreme size would be a sliver. These bounds sit outside every shape seen in practice (phone window about 0.47, ultrawide about 2.3).
    static let tileShapeBounds: ClosedRange<CGFloat> = 0.4...2.5

    /// The thumbnail is asked first since it is what gets drawn; with none, the Mac's reported size gives the same shape, so the tile does not change shape when the picture lands.
    static func tileShape(for descriptor: CaptureSourceDescriptor) -> CGFloat {
        guard let thumbnail = descriptor.thumbnail else { return tileShape(descriptor.pixelSize) }
        return tileShape(CGSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
    }

    /// Without a photograph the screen's shape keeps a desktop tile from resizing when one lands.
    func desktopShape(_ display: SpaceDisplay, index: Int) -> CGFloat {
        guard let preview = display.preview(for: index) else {
            let size = model.catalog?.descriptor(for: .display(display.displayID))?.pixelSize ?? .zero
            return Self.tileShape(size)
        }
        return Self.tileShape(CGSize(width: CGFloat(preview.width), height: CGFloat(preview.height)))
    }

    /// A window is whatever shape the user left it: a shape past the bounds is drawn at the bound, cropping by a small amount.
    static func tileShape(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return tileAspect }
        return min(
            max(size.width / size.height, Self.tileShapeBounds.lowerBound),
            Self.tileShapeBounds.upperBound
        )
    }

    /// A quarter of the gutter either side; the cost is in `tileRoom`.
    static let tileGrowth: CGFloat = 1.045

    /// A scaled tile is wider than its cell and a scroll view clips at its bounds: without this room the first and last tile of every row lost the ends of their border.
    static let tileRoom: CGFloat = 6

    static let iconSize: CGFloat = 56
    static let iconGap: CGFloat = 8

    /// The cap is enforced here rather than by greying rows: a row that cannot be added looks broken, and the Mac is already capturing as many as it will.
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

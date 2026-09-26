import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// The arrangement that is on screen: the way back to it, and the way to change it.
    ///
    /// **Two rows on one card, where there were two pills.** They were a filled blue capsule with
    /// a tinted blue one under it: the same shape twice, so the pair read as a control and its
    /// copy, and neither of them was what this app's blue is for, which is a state and not a
    /// thing you can tap. What is drawn now is the panel's own row, the one the way in above
    /// them and every source below them is built from, and one card around the pair because they
    /// are two things that can be done to one arrangement. The rule between them is
    /// ``Controls/divider``, which is not drawn after a last row.
    ///
    /// **The way back, and it is not in the pill.** Leaving an arrangement by tapping one of its
    /// windows used to leave a chip in the status pill that returned to it; that chip is gone,
    /// and without this row there was no way back at all. It belongs here rather than in the pill
    /// for the same reason the rest of this panel exists: choosing what the picture shows is what
    /// this panel is for, and the arrangement is one of the things it can show. It is drawn only
    /// while the arrangement is *not* the picture, because a row that goes where you already are
    /// is the "button that goes nowhere" this app refuses everywhere else, and it is asked of what
    /// the user asked for rather than of what has arrived, for the reason on
    /// ``MacSession/canReturnToMosaic``.
    @ViewBuilder
    var mosaicEdit: some View {
        VStack(spacing: 0) {
            if model.canReturnToMosaic {
                mosaicAction(
                    icon: "rectangle.split.2x2",
                    title: "Back to the mosaic",
                    detail: arrangementSize
                ) {
                    onReturnToMosaic()
                    onSelect()
                }
                Controls.divider
            }

            mosaicAction(
                icon: "rectangle.on.rectangle",
                title: "Add or remove windows",
                detail: nil
            ) {
                withAnimation(Motion.settle) {
                    picked = model.mosaicChoicesList.compactMap { model.catalog?.descriptor(for: $0.source) }
                    buildingMosaic = true
                }
            }
        }
        .rowSurface()
    }

    /// One of the two things that can be done to the arrangement.
    ///
    /// The glyph, the name and the pad are the way-in row's, which is deliberate: this block is
    /// that row or these two, and they cross-fade into each other, so a row that changed its
    /// measurements on the way would be the whole block moving rather than one thing replacing
    /// another. The chevron is what every row in this app that leads somewhere wears, and the
    /// detail is the count the pill used to carry.
    func mosaicAction(
        icon: String,
        title: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ColorPalette.ink)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.99))
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    /// How many things the arrangement holds.
    ///
    /// **A window, even when a tile is a screen or an application.** That is already this app's
    /// word for a tile: the pill over the picture says "in 4 windows" for the same list, and the
    /// row under this one says "add or remove windows". One word for one thing. It is not always
    /// plural, because a tile can be taken out of the arrangement from the picture and leave one.
    var arrangementSize: String {
        let count = model.mosaicChoicesList.count
        return count == 1 ? "1 window" : "\(count) windows"
    }

    /// Building one: what has been picked, how many may be, and the way to see it.
    @ViewBuilder
    var mosaicPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(picked.isEmpty ? "Pick two or more" : "\(picked.count) picked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("up to \(MosaicLayout.maximumTileCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                // **A way back rather than a way to give up.** This said "Cancel", which is what
                // a sheet says when it is about to throw your work away — and it does throw the
                // picks away, which is right, but "Cancel" is not a word anybody reads as "back
                // to the list I came from". The chevron and the name of the thing it goes back to
                // are, and they are the same control the rest of the app uses for it.
                Button {
                    withAnimation(Motion.settle) {
                        buildingMosaic = false
                        picked = []
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 12, weight: .bold))
                        Text("Sources")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(ColorPalette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(ColorPalette.ink.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(RailButtonStyle(scale: 0.94))
                .accessibilityLabel("Back to the source list")

                Spacer(minLength: 8)

                Button {
                    withAnimation(Motion.settle) {
                        model.showMosaic(picked.map(\.source))
                        buildingMosaic = false
                        picked = []
                    }
                    onSelect()
                } label: {
                    Text("Show mosaic")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(ColorPalette.accent)
                // Two is the fewest that is a mosaic at all, and the cap is the Mac's own: it
                // runs one capture per tile, so the number is the Mac's to decide, and it is
                // read from the same constant the host trims to rather than copied here.
                .disabled(picked.count < 2 || picked.count > MosaicLayout.maximumTileCount)
            }
        }
        // The list's own inset rather than one of its own, so this bar starts and ends where the
        // search field above it does. See ``tileRoom``.
        .padding(.horizontal, Self.tileRoom)
        .padding(.vertical, 10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// One display or window, as a picture with its name under it.
    ///
    /// **The picture is drawn at its own shape inside a box that bounds it.** Every tile used to
    /// *be* a 16:10 box with the picture filled into it, which for a window taller than it is wide
    /// meant the middle stripe of it: an iPhone Simulator window came out looking like a landscape
    /// one with the top and bottom of the phone cut away. The picture is the only reason this
    /// panel draws pictures rather than names, so it is drawn whole; what is bounded is how large
    /// it may be, so a tall window is a narrow tile rather than a tall one. See ``tileBox`` and
    /// ``tileShape(for:)``.
    func previewTile(
        _ descriptor: CaptureSourceDescriptor, fallbackIcon: String
    ) -> some View {
        let placed = placement(of: descriptor)
        let shape = Self.tileShape(for: descriptor)

        return Button {
            choose(descriptor)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Self.tileBox {
                    ColorPalette.surface
                        .overlay {
                            if let thumbnail = descriptor.thumbnail,
                               let image = thumbnails.image(for: descriptor.id, data: thumbnail.jpegData) {
                                Image(uiImage: image)
                                    .resizable()
                                    // Filled, which the shape around it has made the same thing
                                    // as fitted: the box this is drawn into is this picture's
                                    // shape, so there is nothing left over to crop away.
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                // What the tile can honestly show before there is a picture,
                                // which is an ordinary state rather than a failure: the Mac takes
                                // these when it is asked to and not before, so every tile is drawn
                                // this way between the panel opening and the photographs landing.
                                // See ``CaptureSourceResolver/refreshSourceThumbnails()``.
                                Image(systemName: fallbackIcon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .aspectRatio(shape, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    placed.marked
                                        ? ColorPalette.accent
                                        : ColorPalette.ink.opacity(0.18),
                                    lineWidth: placed.marked ? 2 : 1
                                )
                        }
                        // On the picture, not on the box: a number in the corner of a box that is
                        // twice the width of what it sits beside is a number by itself.
                        .overlay(alignment: .topTrailing) { placeBadge(placed.place) }
                }

                // **No wider than the picture it names.** A cell is one shape and the pictures
                // inside it are not: a tall window is drawn as a narrow picture in the middle of a
                // cell-wide box, and its title used to run the full width of the cell, so the name
                // of a sliver of a window was a line of text twice its width with the picture at
                // one end. Clipped to the picture, the two read as one tile. See
                // ``captionWidth(shape:)``.
                caption(descriptor, isLive: placed.isLive)
                    .frame(maxWidth: captionWidth(shape: shape), alignment: .leading)
            }
            // Measured here, from whichever tile lays out first: every cell of an adaptive grid is
            // the same width, and the arithmetic below needs one number for all of them.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(width - tileCellWidth) > 0.5 { tileCellWidth = width }
            }
        }
        // **A tile that has just become the picture steps forward and stays there.** Tapping a
        // source used to change the accent edge and nothing else, which is a mark appearing on a
        // control the user has already finished looking at — the face of the thing they are now
        // watching should be the part that moves. It is the only movement in either grid, and it
        // is small on purpose: a quarter of the gutter either side, so a tile that grows into
        // the gap reads as arriving rather than as a grid that has gone ragged.
        .scaleEffect(placed.isLive ? Self.tileGrowth : 1)
        .animation(Motion.settle, value: placed.isLive)
        .buttonStyle(RailButtonStyle(scale: 0.94))
        // The picture is the point of the tile and carries no text of its own, so the label is
        // what a screen reader announces instead of a wall of unlabelled images.
        .accessibilityLabel(spoken(descriptor))
    }
}

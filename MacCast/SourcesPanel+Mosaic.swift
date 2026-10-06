import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// Two rows on one card: the earlier pair of blue capsules read as a control and its copy, and this app's blue is for a state, not for taps. The rule between them is ``Controls/divider``.
    /// The way back lives here, not in the pill: choosing what the picture shows is what this panel is for. Drawn only while the arrangement is not the picture, asked of what the user asked for rather than what arrived (see `canReturnToMosaic`).
    @ViewBuilder
    var mosaicEdit: some View {
        VStack(spacing: 0) {
            if model.canReturnToMosaic {
                mosaicAction(
                    icon: "rectangle.split.2x2",
                    title: String(localized: "Back to the mosaic"),
                    detail: arrangementSize
                ) {
                    onReturnToMosaic()
                    onSelect()
                }
                Controls.divider
            }

            mosaicAction(
                icon: "rectangle.on.rectangle",
                title: String(localized: "Add or remove windows"),
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

    /// The glyph, name and pad are the way-in row's: the block cross-fades between that row and these two, and changed measurements would make the whole block move.
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

    /// A window, even when a tile is a screen or an application: the pill says "in 4 windows" for the same list. Not always plural, since a tile can be taken out from the picture and leave one.
    var arrangementSize: String {
        let count = model.mosaicChoicesList.count
        return count == 1 ? String(localized: "1 window") : String(localized: "\(count) windows")
    }

    @ViewBuilder
    var mosaicPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(picked.isEmpty ? String(localized: "Pick two or more") : String(localized: "\(picked.count) picked"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("up to \(MosaicLayout.maximumTileCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                // A way back, not a way to give up: "Cancel" is not read as "back to the list I came from", though the picks are thrown away.
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
                // Two is the fewest that is a mosaic, and the cap is the Mac's own (one capture per tile), read from the constant the host trims to.
                .disabled(picked.count < 2 || picked.count > MosaicLayout.maximumTileCount)
            }
        }
        // The list's own inset, so the bar starts and ends where the search field does.
        .padding(.horizontal, Self.tileRoom)
        .padding(.vertical, 10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The picture is drawn at its own shape inside a box that bounds it: filling a 16:10 box cropped a tall window to its middle stripe.
    func previewTile(
        _ descriptor: CaptureSourceDescriptor, fallbackIcon: String, height: CGFloat? = nil
    ) -> some View {
        let placed = placement(of: descriptor)
        let shape = Self.tileShape(for: descriptor)
        let pictureWidth = height.map { $0 * shape }

        let controls = tileControls(for: descriptor)
        let showsControls = !controls.isEmpty && windowControlsFor == descriptor.id
        let isPendingRemoval = pendingVirtualDisplayRemovalIDs.contains(descriptor.id)

        return Button {
            guard Date().timeIntervalSince(windowControlsShownAt) > 0.6 else { return }
            if windowControlsFor != nil {
                withAnimation(Motion.tap) { windowControlsFor = nil }
                return
            }
            choose(descriptor)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Self.tileBox(height: height, shape: shape) {
                    ColorPalette.surface
                        .overlay {
                            if let thumbnail = descriptor.thumbnail,
                               let image = thumbnails.image(for: descriptor.id, data: thumbnail.jpegData) {
                                Image(uiImage: image)
                                    .resizable()
                                    // Filled equals fitted here, as the box is this picture's shape.
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                // Before there is a picture is an ordinary state: the Mac takes thumbnails when asked, so every tile is drawn this way until they land.
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
                        // On the picture, not the box: a number in the corner of a box twice the width of what it sits beside is a number by itself.
                        .overlay(alignment: .topTrailing) { placeBadge(placed.place) }
                        .overlay {
                            if showsControls {
                                tileControlBar(
                                    controls,
                                    stacked: (pictureWidth ?? captionWidth(shape: shape))
                                        < Self.controlBarWidth(count: controls.count)
                                )
                            }
                        }
                }

                // No wider than the picture it names: a tall window's title ran the cell's full width with the picture at one end. See ``captionWidth(shape:)``.
                caption(descriptor, isLive: placed.isLive)
                    .frame(maxWidth: pictureWidth ?? captionWidth(shape: shape), alignment: .leading)
            }
            .frame(width: pictureWidth)
            // Measured from whichever tile lays out first: every cell of an adaptive grid is the same width.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if height == nil, abs(width - tileCellWidth) > 0.5 { tileCellWidth = width }
            }
        }
        // A tile that has just become the picture steps forward and stays there: tapping used to change the accent edge only. Small on purpose: a quarter of the gutter either side.
        .scaleEffect(placed.isLive ? Self.tileGrowth : 1)
        .animation(Motion.settle, value: placed.isLive)
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .disabled(isPendingRemoval)
        .opacity(isPendingRemoval ? 0.5 : 1)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                guard !controls.isEmpty, !buildingMosaic else { return }
                windowControlsShownAt = Date()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(Motion.morph) { windowControlsFor = descriptor.id }
            }
        )
        // The picture carries no text, so the label is what a screen reader announces.
        .accessibilityLabel(spoken(descriptor))
    }

    func tileControls(for descriptor: CaptureSourceDescriptor) -> [TileControl] {
        switch descriptor.source {
        case .window(let id):
            let send = { (action: WindowAction) in
                model.send(.performWindowAction(windowID: id, action: action))
            }
            return [
                TileControl(colour: TileControl.red, symbol: "xmark", label: String(localized: "Close window")) { send(.close) },
                TileControl(colour: TileControl.yellow, symbol: "minus", label: String(localized: "Minimise window")) { send(.minimize) },
                TileControl(colour: TileControl.green, symbol: "arrow.up.left.and.arrow.down.right", label: String(localized: "Zoom window")) { send(.zoom) },
            ]
        case .display(let id) where descriptor.isManagedVirtualDisplay && includesVirtualDisplays:
            return [
                TileControl(colour: TileControl.red, symbol: "xmark", label: String(localized: "Remove \(descriptor.title)")) {
                    removeVirtualDisplay(descriptor, id: id)
                },
                TileControl(colour: TileControl.yellow, symbol: "pencil", label: String(localized: "Rename \(descriptor.title)")) {
                    renameVirtualDisplayDraft = descriptor.title
                    renameVirtualDisplayTarget = descriptor
                },
            ]
        default:
            return []
        }
    }

    /// The one place the panel uses colours other than the state blue: they quote the Mac's title-bar buttons.
    /// Stacked on a tile too narrow for a row: a row of three would hang off both edges and be clipped by the scroll row.
    @ViewBuilder
    func tileControlBar(_ controls: [TileControl], stacked: Bool = false) -> some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: Self.controlSpacing))
        layout {
            ForEach(controls) { tileControlButton($0, size: stacked ? 22 : Self.controlSize) }
        }
        .padding(stacked ? 5 : Self.controlPadding)
        .glassSurface(in: Capsule())
        .transition(Self.badge)
    }

    static let controlSize: CGFloat = 26
    static let controlSpacing: CGFloat = 10
    static let controlPadding: CGFloat = 8

    static func controlBarWidth(count: Int) -> CGFloat {
        CGFloat(count) * controlSize + CGFloat(max(count - 1, 0)) * controlSpacing + 2 * controlPadding
    }

    @ViewBuilder
    private func trafficLight(_ colour: Color) -> some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(colour).interactive(), in: Circle())
        } else {
            Circle().fill(colour)
        }
    }

    private func tileControlButton(_ control: TileControl, size: CGFloat) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            control.action()
            withAnimation(Motion.tap) { windowControlsFor = nil }
        } label: {
            trafficLight(control.colour)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: control.symbol)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                }
                .contentShape(Circle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.85))
        .accessibilityLabel(control.label)
    }
}

struct TileControl: Identifiable {
    static let red = Color(red: 1.0, green: 0.37, blue: 0.34)
    static let yellow = Color(red: 1.0, green: 0.74, blue: 0.18)
    static let green = Color(red: 0.16, green: 0.79, blue: 0.25)

    let colour: Color
    let symbol: String
    let label: String
    let action: () -> Void
    var id: String { label }
}

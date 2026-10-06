import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// "Which screen" and "which desktop of it" are one question at two depths, so a screen is drawn as its desktops.
    /// One row per screen: the grouping says which desktops belong to which screen, where one flat strip would show two "Desktop 1".
    /// A picture for screens and windows, which answer "which had the thing I was on"; applications are identities, so they get an icon.
    @ViewBuilder
    func screensSection(_ descriptors: [CaptureSourceDescriptor]) -> some View {
        // Real screens only, apart from building a mosaic: a virtual display has its own group otherwise, but a mosaic is picked from tiles with a badge showing where each landed, which that group does not draw.
        let matches = filtered(descriptors).filter { buildingMosaic || !$0.isVirtualDisplay }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "Screens"))
                if buildingMosaic {
                    // Said here because the tap moves the Mac: a tile is a live capture, and a desktop not on the display has nothing to capture, so choosing a desktop is choosing which one the screen is on.
                    // The tap is a move, not a second tile: a screen is one source, so a second desktop replaces the first, and doing it quietly would look like a failure.
                    Text("Picking a desktop switches that Mac's screen to it. A screen is in the arrangement once, so picking another of its desktops moves that tile rather than adding one.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(matches) { screenBlock($0) }
            }
        }
    }

    /// Two refusals reach one branch: a Mac with no space catalogue, and one whose Space reader skipped this display, both leave the lookup empty. A search is by window name and desktops have none.
    /// Desktops are drawn while assembling an arrangement too, where the tap moves the Mac as well as the arrangement: see `chooseDesktopForMosaic`.
    @ViewBuilder
    func screenBlock(_ descriptor: CaptureSourceDescriptor) -> some View {
        if let info = model.catalog?.spaceInfo,
           Self.showsDesktops(info),
           query.isEmpty,
           let display = info.displays.first(where: { descriptor.source == .display($0.displayID) }),
           display.count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if namesScreen(info, display) { chip(for: display) }

                Self.tileRow {
                    // Offsets rather than `1...count`, an empty range that traps when a display reports nothing.
                    ForEach(0..<display.count, id: \.self) { offset in
                        desktopTile(
                            display,
                            index: offset + 1,
                            screen: descriptor,
                            showsScreenName: info.displays.count > 1
                        )
                    }
                }
            }
        } else {
            previewTile(descriptor, fallbackIcon: "display", height: Self.packedTileHeight)
        }
    }

    /// Drawn when `namesScreen` says so. Above the tiles and hugging its text: display names are arbitrary strings, and a fixed width would truncate real names.
    /// Filled when the video is showing that screen: that is what the app means by "this one is on" (``ColorPalette/selectedFill``).
    func chip(for display: SpaceDisplay) -> some View {
        let showing = isShowing(display)

        return HStack(spacing: 4) {
            if showing {
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
        .background(showing ? ColorPalette.selectedFill : ColorPalette.surface, in: Capsule())
        .overlay {
            // The hairline gives the resting chip a body; on the filled one a border would dull the accent.
            Capsule().strokeBorder(ColorPalette.ink.opacity(showing ? 0 : 0.15))
        }
        .animation(Motion.tap, value: showing)
    }

    func name(of display: SpaceDisplay) -> String {
        model.catalog?.descriptor(for: .display(display.displayID))?.title ?? String(localized: "Display")
    }

    /// The same test as `placement(of:)` from the other side: `descriptor.id` and `CaptureSource.display(id).stableID` are one string spelled two ways, and a desktop tile has no descriptor.
    func isShowing(_ display: SpaceDisplay) -> Bool {
        model.activeSourceID == CaptureSource.display(display.displayID).stableID
    }

    /// Two reasons: with more than one screen the name says which row belongs to which; with one, the chip carries the mark that this screen is watched, which has nowhere else to live when a fullscreen app is showing (`current` is nil, so no tile is current).
    func namesScreen(_ info: SpaceInfo, _ display: SpaceDisplay) -> Bool {
        info.displays.count > 1 || (isShowing(display) && display.current == nil)
    }

    /// A picture because "which one had my browser" is not answerable by a number; each tile was photographed when that desktop was last active.
    /// `isCurrent` is where that screen is (every display has one) and `isLive` is where the phone is looking (exactly one). Suppressing the first made tapping "desktop 2" on a screen already on desktop 2 a visible non-event that read as broken.
    /// `current` nil means a fullscreen app is on the display and no tile is current; `namesScreen` covers the fact that would be lost.
    /// In the accumulating mode the tile chooses which desktop the screen contributes by moving the screen there, and the mark sits on the desktop the screen is on, which the finished mosaic will show.
    func desktopTile(
        _ display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor, showsScreenName: Bool
    ) -> some View {
        let showing = isShowing(display)
        let isCurrent = desktopIsCurrent(display, index: index)
        let isLive = showing && isCurrent

        // A desktop is not a source, so every desktop of one screen answers with the same place and only the showing one wears it.
        let placed = placement(of: screen)
        let marked = buildingMosaic ? (placed.marked && isCurrent) : isLive
        // The desktop's own picture, so a rotated or non-16:10 screen is not cropped, and the screen's shape before one arrives so the tile does not change shape.
        let shape = desktopShape(display, index: index)

        return Button {
            if buildingMosaic {
                chooseDesktopForMosaic(display: display, index: index, screen: screen)
            } else {
                switchToDesktop(display: display, index: index)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Self.tileBox(height: Self.packedTileHeight, shape: shape) {
                    ColorPalette.surface
                        .overlay {
                            if let data = display.preview(for: index)?.jpegData,
                               let image = thumbnails.image(
                                   for: "\(display.displayID)-\(index)",
                                   data: data
                               ) {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                // An empty tile is the truth: this desktop has not been on screen since the host started, and a placeholder would picture a desktop that does not exist.
                                Image(systemName: "rectangle.dashed")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .aspectRatio(shape, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    marked
                                        ? ColorPalette.accent
                                        : ColorPalette.ink.opacity(isCurrent ? 0.5 : 0.18),
                                    lineWidth: marked ? 2 : (isCurrent ? 1.5 : 1)
                                )
                        }
                        .overlay(alignment: .topTrailing) { placeBadge(marked ? placed.place : nil) }
                }

                Text(isLive ? String(localized: "Desktop \(index) · here") : String(localized: "Desktop \(index)"))
                    .font(.system(size: 10, weight: marked ? .semibold : .regular))
                    .foregroundStyle(
                        marked
                            ? ColorPalette.accent
                            : (isCurrent ? ColorPalette.ink : Color.secondary)
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Self.packedTileHeight * shape)
        }
        // The tile that has just become the picture steps forward, as in the grids above. Driven by the desktop being current rather than the mark, which also means something else now: a tile that stepped forward on gaining a number would move in a grid still being chosen from.
        .scaleEffect(isLive ? Self.tileGrowth : 1)
        .animation(Motion.settle, value: isLive)
        .animation(Motion.morph, value: placed.marked)
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(
            spokenDesktop(
                display,
                index: index,
                showsScreenName: showsScreenName,
                isLive: isLive,
                isCurrent: isCurrent,
                picks: buildingMosaic && placed.marked && isCurrent
            )
        )
    }

    /// A tile in an arrangement is a live capture, and a desktop not on the display has no pixels, so choosing a desktop is choosing which one the screen is on. The space switch goes out first so picture and arrangement agree.
    /// No source is selected and the panel is not closed: assembling is not watching, and either would end the picking after one tap.
    func chooseDesktopForMosaic(
        display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor
    ) {
        let isPicked = picked.contains { $0.source == screen.source }

        // Tapping the desktop the screen is already on, when it is already in, is the way back out.
        // Asked through `desktopIsCurrent(_:index:)` so the tile drawn as "here" is the one that takes the screen out, even before the Mac's answer arrives.
        if isPicked, desktopIsCurrent(display, index: index) {
            withAnimation(Motion.morph) { toggle(screen) }
            return
        }

        askForDesktop(display, index: index)
        if !isPicked {
            withAnimation(Motion.morph) { toggle(screen) }
        }
    }

    /// One door for both taps that move a screen.
    func askForDesktop(_ display: SpaceDisplay, index: Int) {
        guard !desktopIsCurrent(display, index: index) else { return }
        let pending = PendingDesktop(display: display.displayID, index: index)
        pendingDesktop = pending
        model.send(.switchToSpace(display: display.displayID, index: index))
        // Bounded because a refusal is silent: a refused switch leaves the list as it was, so nothing in it would give the mark up.
        Task {
            try? await Task.sleep(for: Self.pendingDesktopTimeout)
            if pendingDesktop == pending { pendingDesktop = nil }
        }
    }

    /// Longer than the host's three-second catalogue coalescing (see `refreshCatalog()`) plus the enumeration, so the mark is given up when the Mac's answer arrives, not just before.
    static let pendingDesktopTimeout: Duration = .seconds(6)

    func desktopIsCurrent(_ display: SpaceDisplay, index: Int) -> Bool {
        // A tap on this screen answers for it until the Mac does, so the old desktop loses its mark as the new one gains it.
        if let pending = pendingDesktop, pending.display == display.displayID {
            return pending.index == index
        }
        return index == display.current
    }

    /// The screen's name comes first with more than one screen: a screen reader gets no chip above the row.
    func spokenDesktop(
        _ display: SpaceDisplay,
        index: Int,
        showsScreenName: Bool,
        isLive: Bool,
        isCurrent: Bool,
        picks: Bool
    ) -> String {
        let state: String
        if picks {
            state = String(localized: ", in the mosaic")
        } else if buildingMosaic, isCurrent {
            // The way out, said as such: a screen reader has no badge or accent to tell it.
            state = String(localized: ", current, tap to remove this screen")
        } else if buildingMosaic {
            state = String(localized: ", tap to switch this screen here")
        } else {
            state = isLive ? String(localized: ", showing") : (isCurrent ? String(localized: ", current") : "")
        }
        return showsScreenName
            ? String(localized: "\(name(of: display)) Desktop \(index)\(state)")
            : String(localized: "Desktop \(index)\(state)")
    }

    /// A desktop tile names a screen too, so a tap is a statement about where to look: switching only the Space left the user watching one screen while another rearranged off-camera.
    /// The Space goes out first, so the Mac rearranges the desktop while the picture is where it was; the other order shows the screen being left and then a second jump.
    func switchToDesktop(display: SpaceDisplay, index: Int) {
        askForDesktop(display, index: index)

        let source = CaptureSource.display(display.displayID)
        if model.activeSourceID != source.stableID {
            // Through the model so the choice is recorded: the raw send moved the host without `activeSourceID`, so the next tap back looked like no move.
            model.selectSource(source)
        }
        onSelect()
    }

    /// More than one desktop or more than one screen: a second screen qualifies alone since tapping its desktop moves the picture there.
    /// Read by ``RemoteScreen`` too, so the command that freshens the desktop pictures and the grid are gated on one answer.
    static func showsDesktops(_ info: SpaceInfo) -> Bool {
        info.totalCount > 1 || info.displays.count > 1
    }
}

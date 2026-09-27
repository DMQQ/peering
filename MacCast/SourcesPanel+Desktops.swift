import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// Every screen, with its desktops under it.
    ///
    /// **This is where the desktops panel went.** "Which screen am I looking at" and "which
    /// desktop of it" are one question asked at two depths, and they were two floating panels
    /// behind two buttons that each listed the displays. A screen is drawn as its desktops now:
    /// the screen is named once rather than twice, and the tap that moves the picture is the same
    /// tap that picks the source.
    ///
    /// **One row per screen, and the row is the information.** A Mac with two screens shows two
    /// rows here and each row correctly has a current desktop of its own, so the grouping is what
    /// says which desktops belong to which screen. One flat strip of tiles would be several
    /// unlabelled pictures two of which are called "Desktop 1".
    ///
    /// **A picture, which is what this section and the windows below it have in common.** A
    /// screen and a window are somewhere you are looking, and the question somebody opens this
    /// panel with is "which one had the thing I was on it", which only a picture answers: every
    /// Mac's windows are a different arrangement of the same few greys. An application, and an
    /// application that is not running yet, are identities instead, and an icon is the thing that
    /// says which one it is in a way a photograph of one of its windows does not.
    @ViewBuilder
    func screensSection(_ descriptors: [CaptureSourceDescriptor]) -> some View {
        // Real screens only, apart from building a mosaic. A virtual display has its own
        // labelled group in ``virtualDisplaysSection`` the rest of the time, so it does not also
        // turn up here as an unmarked tile indistinguishable from a real monitor — but a mosaic
        // is picked from tiles with a badge showing where each one landed, which that group does
        // not draw, so excluding it there instead would have made a virtual display the one
        // source in the app that cannot go into an arrangement.
        let matches = filtered(descriptors).filter { buildingMosaic || !$0.isVirtualDisplay }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Screens")
                if buildingMosaic {
                    // **Said here because the tap moves the Mac**, which is not what a picker is
                    // expected to do and is the one thing about this panel worth warning a user
                    // about before they meet it rather than after.
                    //
                    // There is no alternative to it. A tile is a live capture of a display, and a
                    // desktop that is not on that display has no pixels in existence to capture,
                    // so choosing which desktop a screen contributes *is* choosing which desktop
                    // that screen is on.
                    //
                    // And the tap is a *move* rather than a second tile: a screen is one source, so
                    // the second desktop of a screen already in the arrangement replaces the first.
                    // Said here because a tap that quietly did that looks like one that failed.
                    Text("Picking a desktop switches that Mac's screen to it. A screen is in the arrangement once, so picking another of its desktops moves that tile rather than adding one.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(matches) { screenBlock($0) }
            }
        }
    }

    /// One screen: its desktops, or the screen itself where the desktops cannot be drawn.
    ///
    /// **Two things refuse them and they are different refusals, reached from one branch.** A Mac
    /// that has sent no space catalogue has said nothing about its desktops, and a Mac whose Space
    /// reader skipped this particular display has said nothing about that one, which is the same
    /// answer: the catalogue lookup comes back empty either way, and the display's own tile is
    /// then the only control that still selects it. A search is looking for a window by name, and
    /// a desktop has no name of its own, so a block of them above the results would only push what
    /// was searched for below the fold.
    ///
    /// **The desktops are drawn while an arrangement is being assembled too, and they mean
    /// something different there.** Choosing which desktop a screen contributes is choosing which
    /// desktop that screen is *on*, because a tile is a live capture and a desktop that is not on
    /// the display has no pixels to capture. So the tap moves the Mac as well as the arrangement:
    /// see ``chooseDesktopForMosaic(display:index:screen:)``. They are drawn rather than replaced
    /// by the screen's own tile because that is the whole of the choice being offered, and a
    /// picker that hides the options is not offering one.
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
                    // Offsets rather than `1...count`, which is an empty range when a display
                    // reports nothing and traps on the way.
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

    /// A screen's name, on its own line above that screen's desktops.
    ///
    /// Drawn when ``namesScreen(_:_:)`` says so, which is either because there is more than one
    /// screen to tell apart or because the tiles under it have lost the mark that says where the
    /// phone is looking. Above the tiles rather than beside them, and hugging its text rather than
    /// given a width: display names are arbitrary user-facing strings, and a fixed width would
    /// mean truncating real names to fit around a thumbnail.
    ///
    /// Filled rather than tinted when the video is showing that screen, because that is what this
    /// app already means by "this one is on" (see ``ColorPalette/selectedFill``, and the same
    /// mark on the sources list). A bare checkmark rather than the circled one used there: that
    /// one sits on a dark row and needs the disc to carry it, while this sits on the fill itself.
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
            // The hairline is what gives the resting chip a body. On the filled one it is the
            // fill doing that, and a border would only dull the accent.
            Capsule().strokeBorder(ColorPalette.ink.opacity(showing ? 0 : 0.15))
        }
        .animation(Motion.tap, value: showing)
    }

    func name(of display: SpaceDisplay) -> String {
        model.catalog?.descriptor(for: .display(display.displayID))?.title ?? "Display"
    }

    /// Whether the picture on the phone is of this screen.
    ///
    /// **The same test ``placement(of:)`` makes, written from the other side.** A descriptor's
    /// `id` *is* its source's ``CaptureSource/stableID``, so `descriptor.id` and
    /// `CaptureSource.display(id).stableID` are one string spelled two ways. A desktop tile has no
    /// descriptor to hand, so it is spelled this way here, and everything in this section that
    /// asks the question goes through this one property rather than writing the comparison twice.
    func isShowing(_ display: SpaceDisplay) -> Bool {
        model.activeSourceID == CaptureSource.display(display.displayID).stableID
    }

    /// Whether a screen needs its name above its tiles.
    ///
    /// **Two reasons, and they are different questions.** With more than one screen, the name is
    /// what says which screen the row of tiles belongs to, and that grouping is the whole reason
    /// the screens are separate rows rather than one flat grid. With one screen there is nothing
    /// to tell apart, and the chip is drawn for the other thing it carries instead: the mark that
    /// *this* is the screen being watched. That mark has nowhere else to live when the display is
    /// showing a fullscreen application, because `current` is nil then and no tile is the current
    /// desktop, so the row of tiles would otherwise say nothing at all about where the phone is
    /// looking. Exactly the case where the tiles have no answer is the case where the chip does.
    func namesScreen(_ info: SpaceInfo, _ display: SpaceDisplay) -> Bool {
        info.displays.count > 1 || (isShowing(display) && display.current == nil)
    }

    /// One desktop of one screen, as a picture with its number under it.
    ///
    /// **A picture rather than a list of numbers**, because the question being asked is "which one
    /// had my browser on it", and a number cannot answer that. Each tile is a photograph taken
    /// when that desktop was last active, which is the only kind there can be: the other desktops
    /// are by definition not on the display being captured. See ``SpacePreview``.
    ///
    /// **Two facts are drawn, and they are different facts.** `isCurrent` is where *that screen*
    /// is, and every display has one of its own, so two highlighted tiles across two screens is
    /// the honest answer rather than a fault. `isLive` is where the phone is looking, and exactly
    /// one desktop can be it. Suppressing the first to fix the second was a worse trade: the
    /// screen you are not watching then says nothing about where it is, so tapping "desktop 2" on
    /// a screen already showing desktop 2 becomes a coin toss. It is not a no-op a user can see.
    /// The panel closes, the picture does not move, and it reads as broken.
    ///
    /// `current` is optional and nil means a fullscreen application is on that display, which has
    /// no current desktop to mark. Comparing through the optional gives exactly that answer: no
    /// tile is current. ``namesScreen(_:_:)`` is what covers the fact that would otherwise be
    /// lost with it.
    ///
    /// **Two jobs, and the tile says which one it is doing.** In the ordinary pick it reveals the
    /// desktop and takes the picture with it. In the accumulating one it chooses which desktop
    /// that screen contributes to the arrangement, which it can only do by moving the screen
    /// there, and the mark moves with it: the accent and the arrangement's number sit on the
    /// desktop the screen is *on*, because that is the one the finished mosaic will show.
    func desktopTile(
        _ display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor, showsScreenName: Bool
    ) -> some View {
        let showing = isShowing(display)
        let isCurrent = desktopIsCurrent(display, index: index)
        let isLive = showing && isCurrent

        // What the arrangement has to say about this screen, asked once. A desktop is not a
        // source, so every desktop of one screen answers with the same place, and only the one
        // that is showing wears it: three tiles carrying "2" is the same arrangement reported
        // three times, which is not three things.
        let placed = placement(of: screen)
        let marked = buildingMosaic ? (placed.marked && isCurrent) : isLive
        // The desktop's own picture, so a screen that is rotated or not 16:10 is not cropped, and
        // the screen's own shape when there is no picture yet, so the tile does not change shape
        // when one arrives. See ``tileShape(for:)``.
        let shape = desktopShape(display, index: index)

        return Button {
            if buildingMosaic {
                chooseDesktopForMosaic(display: display, index: index, screen: screen)
            } else {
                switchToDesktop(display: display, index: index)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                // The same box and the same picture the preview tiles are built from, so a row of
                // desktops and a row of windows are measured the same way. A desktop's own
                // picture goes in it at the screen's shape rather than at 16:10.
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
                                // An empty tile is the truth: this desktop has not been on screen
                                // since the host started, so there is no picture of it to show. A
                                // placeholder image would be a picture of a desktop that does not
                                // exist.
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

                Text(isLive ? "Desktop \(index) · here" : "Desktop \(index)")
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
        // The tile that has just become the picture steps forward, exactly as it does in the
        // grids above: the face of the thing the user is now watching should be the part that
        // moves. A quarter of the gutter either side, so a tile that grows into the gap reads as
        // arriving rather than as a grid that has gone ragged.
        //
        // Driven by the desktop being current rather than by the mark, because the mark means two
        // things now and only one of them is a tile arriving. A tile that stepped forward when it
        // gained a number would be moving in a grid the user is still choosing from.
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

    /// Chooses which desktop a screen contributes to the arrangement, which moves the screen.
    ///
    /// **The only way this can work, and it is worth being plain about why.** A tile in an
    /// arrangement is a live capture of a display. A desktop that is not on that display is not
    /// being rendered, so it has no pixels in existence to capture, and the choice of which
    /// desktop a screen contributes is therefore the choice of which desktop that screen is on.
    /// The space switch goes out first so the picture and the arrangement agree by the time the
    /// arrangement is built.
    ///
    /// **No source is selected and the panel is not closed**, both deliberately. Assembling is not
    /// watching: selecting a source here would take the user out of the mosaic they are still
    /// putting together, and closing the panel would end the session of picking after one tap.
    func chooseDesktopForMosaic(
        display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor
    ) {
        let isPicked = picked.contains { $0.source == screen.source }

        // Tapping the desktop the screen is already on, when that screen is already in, is the
        // way back out. Every other tap moves the screen, and a tap that moved it to where it
        // already is would be a tap that did nothing at all.
        //
        // Asked through ``desktopIsCurrent(_:index:)`` rather than of the Mac's list, so the tile
        // that is drawn as "here" is the tile that takes the screen out, even in the seconds before
        // the Mac's answer to a switch arrives.
        if isPicked, desktopIsCurrent(display, index: index) {
            withAnimation(Motion.morph) { toggle(screen) }
            return
        }

        askForDesktop(display, index: index)
        if !isPicked {
            withAnimation(Motion.morph) { toggle(screen) }
        }
    }

    /// Asks the Mac to show a desktop, and takes the mark here until the Mac's list says so.
    ///
    /// One door for the two taps that move a screen, because assembling an arrangement moves it
    /// exactly as watching one does. See ``pendingDesktop``.
    func askForDesktop(_ display: SpaceDisplay, index: Int) {
        guard !desktopIsCurrent(display, index: index) else { return }
        let pending = PendingDesktop(display: display.displayID, index: index)
        pendingDesktop = pending
        model.send(.switchToSpace(display: display.displayID, index: index))
        // **Bounded, because a refusal is silent.** A switch the window server would not make
        // leaves the Mac's list exactly as it was, so there is nothing in it to give the mark up
        // for; the other half, a list that says something new, is watched for in the panel's body.
        Task {
            try? await Task.sleep(for: Self.pendingDesktopTimeout)
            if pendingDesktop == pending { pendingDesktop = nil }
        }
    }

    /// How long a mark taken at a tap is trusted before the panel stops waiting to be told.
    ///
    /// Longer than the host's own coalescing of catalogue pushes (three seconds, see
    /// ``VideoCoordinator/refreshCatalog()``), with room on top for the enumeration the push itself
    /// has to make: the mark should be given up when the Mac's answer arrives, not just before it.
    static let pendingDesktopTimeout: Duration = .seconds(6)

    /// Which desktop a screen is on, as the tile that says "here" should read it.
    ///
    /// The Mac's own answer, or the one this phone has just asked for and has not yet seen it
    /// confirm. See ``pendingDesktop``.
    func desktopIsCurrent(_ display: SpaceDisplay, index: Int) -> Bool {
        // A tap on this screen answers for it until the Mac does, so the desktop being left loses
        // its mark at the same moment the new one gains it rather than when the list arrives.
        if let pending = pendingDesktop, pending.display == display.displayID {
            return pending.index == index
        }
        return index == display.current
    }

    /// What a desktop tile is called out loud.
    ///
    /// The screen's name comes first when there is more than one screen, because the chip above
    /// the row is a visual grouping and a screen reader does not get one: a list of "Desktop 1,
    /// Desktop 2, Desktop 1" is three tiles with no way to tell which screen the last one is on.
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
            state = ", in the mosaic"
        } else if buildingMosaic, isCurrent {
            // The way out, said as such: this is the one tap that takes the screen back out, and
            // a screen reader reaching the tile has no badge and no accent to tell it.
            state = ", current, tap to remove this screen"
        } else if buildingMosaic {
            state = ", tap to switch this screen here"
        } else {
            state = isLive ? ", showing" : (isCurrent ? ", current" : "")
        }
        return showsScreenName
            ? "\(name(of: display)) Desktop \(index)\(state)"
            : "Desktop \(index)\(state)"
    }

    /// Reveals a desktop, and takes the picture with it. Always both.
    ///
    /// A desktop tile names a *screen* as well as a desktop, so tapping one is a statement about
    /// where to look. Switching only the Space left the user watching one screen while another
    /// rearranged itself off-camera, and when the source was a window rather than a display,
    /// which follows its window wherever that window is, nothing visible happened at all.
    ///
    /// The Space goes out first so the move reads as one thing. The Mac rearranges the desktop
    /// that was asked for while the picture is still where it was, and the picture then arrives
    /// on it already showing the right thing; the other order shows the screen being left, and
    /// then a second jump.
    func switchToDesktop(display: SpaceDisplay, index: Int) {
        askForDesktop(display, index: index)

        let source = CaptureSource.display(display.displayID)
        if model.activeSourceID != source.stableID {
            // Through the model rather than `send`, so the choice is recorded as well as made.
            // The raw send moved the host without moving `activeSourceID`, so the next tap back
            // to a display already named there looked like no move at all and sent nothing.
            model.selectSource(source)
        }
        // The panel stays open: desktops are flicked through to find the right one, and a tap on
        // the picture closes it once they have.
    }

    /// Whether the desktops are worth drawing at all.
    ///
    /// More than one desktop, **or** more than one screen. A second screen qualifies on its own
    /// even with a single desktop on it, because tapping that desktop is how the picture is moved
    /// to it: a control that can only ever do nothing is clutter, and this one can do something.
    /// With one screen and one desktop there is nothing to switch to and nothing to tell apart,
    /// and that screen draws the source tile this panel has always drawn for it.
    ///
    /// Read by ``RemoteScreen`` as well as by ``screenBlock(_:)``, and that is the point of it
    /// being here rather than inline: the command that freshens the desktop pictures and the grid
    /// that draws them are gated on one answer, so the panel cannot ask a Mac for photographs of
    /// tiles it is not going to draw.
    static func showsDesktops(_ info: SpaceInfo) -> Bool {
        info.totalCount > 1 || info.displays.count > 1
    }
}

import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// What the Mac can be made to share, as a floating panel.
///
/// The same list the sheet used to hold, rebuilt for a panel instead of a `List`. A `List` brings
/// its own backgrounds, separators and inset behaviour, none of which survive being put on top of
/// live video inside a sheet of glass — and the panel was already the shape every other control
/// on this screen uses. Search stays: a Mac with twenty running applications and a hundred
/// installed ones needs it more here than it did full-screen, not less.
struct SourcesPanel: View {
    @Environment(SessionModel.self) private var model

    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// Called once the user has picked a source or opened an application, so the caller can put the
    /// panel away — see the setting it consults.
    var onSelect: () -> Void = {}

    /// Returns to the arrangement through the screen's picture animation.
    var onReturnToMosaic: () -> Void = {}

    @State private var query = ""

    /// Whether the panel is picking several sources rather than one.
    ///
    /// **A mode rather than a second panel.** Choosing a mosaic is the same act as choosing a
    /// source — the same list, the same rows — with one difference: the tapping accumulates
    /// instead of switching. A separate picker would be the same list twice, and the second one
    /// would be the one that falls behind when a window opens.
    @State private var buildingMosaic = false

    /// What has been picked, in the order it was picked. The order is the arrangement: the grid
    /// is filled in reading order, so a tile's place is the place it was chosen in.
    @State private var picked: [CaptureSourceDescriptor] = []

    var body: some View {
        // **Everything scrolls, and only the picking controls are pinned.**
        //
        // The panel used to hold a search field and the mosaic block above a scroll view. In
        // landscape that is fatal rather than untidy: the panel is as tall as the screen less the
        // status pill — about 370 points — and an arrangement of five tiles is 250 of them, so
        // the source grids underneath were left a strip too short to show a row of anything,
        // which reads as the picker having gone missing. Nothing is fixed-height now, so there is
        // no arrangement of contents that can squeeze another part of the panel out of existence.
        //
        // What stays put is the pair of controls that end the mode. Those are the way out, they
        // have to be reachable from anywhere in a list the user is scrolling, and a "Cancel" that
        // scrolled off the top is the same defect as a back button that is not drawn.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                searchField

                // **Two arrangements of one slot, and they cross-fade into each other.** The
                // state that chooses between them is written inside `withAnimation` at each of
                // the places that moves it, so the panel reads as one thing changing what it is
                // showing rather than as a section being torn out and another dropped in.
                if !buildingMosaic {
                    if model.mosaicChoicesList.isEmpty { mosaicEntry } else { mosaicEdit }
                }

                if let catalog = model.catalog, !catalog.all.isEmpty {
                    screensSection(catalog.displays)
                    // **One section per application, with its windows under it.** The catalogue
                    // offers applications and windows as two flat lists, which is what the Mac
                    // can enumerate rather than what anybody is looking for: a Mac with ten
                    // applications and twenty-five windows becomes two lists of two different
                    // things, and finding your browser means reading both and working out which
                    // window belongs to what. See ``SourceGrouping``.
                    ForEach(filteredGroups) { group in
                        applicationSection(group)
                    }
                    if !buildingMosaic { installedGrid }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle.slash")
                            .foregroundStyle(.secondary)
                        Text("The Mac has not sent its list of displays and windows yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
            }
            // Inside the scroll view, because the scroll view's own bounds are what clips a tile
            // that has grown past its cell. See ``tileRoom``.
            .padding(Self.tileRoom)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if buildingMosaic { mosaicPicker }
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Find a display, application or window", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ColorPalette.surface, in: Capsule())
    }

    /// The way in, offered only where it can actually be used.
    ///
    /// Two things can refuse it and they are different refusals. A **plan** without the mosaic
    /// draws the row as itself, dimmed, with the badge on its corner and the paywall behind the
    /// tap, which is what every gated control in this app does. A **Mac** that does not know the
    /// request exists gets no row at all: there is nothing to sell and nothing to try, and the
    /// command it would send is one an older host cannot decode. See ``MosaicSupport``.
    @ViewBuilder
    private var mosaicEntry: some View {
        if model.hostSupportsMosaic {
            PlanLocked(capability: .mosaic, placement: .trailing) {
                Button {
                    // Animated rather than assigned, because this swaps three whole sections of
                    // the panel for another arrangement of them. See the note on the panel's own
                    // body for why the transition is here and not on the view.
                    withAnimation(Motion.settle) {
                        buildingMosaic = true
                        picked = []
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.split.2x2")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ColorPalette.ink)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Mosaic")
                                .font(.subheadline.weight(.medium))
                            Text("Pick several, and see them all at once")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .rowSurface()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

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
    private var mosaicEdit: some View {
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
    private func mosaicAction(
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
    private var arrangementSize: String {
        let count = model.mosaicChoicesList.count
        return count == 1 ? "1 window" : "\(count) windows"
    }

    /// Building one: what has been picked, how many may be, and the way to see it.
    @ViewBuilder
    private var mosaicPicker: some View {
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
    private func previewTile(
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
                               let image = UIImage(data: thumbnail.jpegData) {
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

                caption(descriptor, isLive: placed.isLive)
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
    private func screensSection(_ descriptors: [CaptureSourceDescriptor]) -> some View {
        let matches = filtered(descriptors)
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
                    Text("Picking a desktop switches that Mac's screen to it.")
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
    private func screenBlock(_ descriptor: CaptureSourceDescriptor) -> some View {
        if let info = model.catalog?.spaceInfo,
           Self.showsDesktops(info),
           query.isEmpty,
           let display = info.displays.first(where: { descriptor.source == .display($0.displayID) }),
           display.count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if namesScreen(info, display) { chip(for: display) }

                LazyVGrid(columns: Self.previewColumns, alignment: .leading, spacing: Self.tileGap) {
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
            LazyVGrid(columns: Self.previewColumns, alignment: .leading, spacing: Self.tileGap) {
                previewTile(descriptor, fallbackIcon: "display")
            }
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
    private func chip(for display: SpaceDisplay) -> some View {
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

    private func name(of display: SpaceDisplay) -> String {
        model.catalog?.descriptor(for: .display(display.displayID))?.title ?? "Display"
    }

    /// Whether the picture on the phone is of this screen.
    ///
    /// **The same test ``placement(of:)`` makes, written from the other side.** A descriptor's
    /// `id` *is* its source's ``CaptureSource/stableID``, so `descriptor.id` and
    /// `CaptureSource.display(id).stableID` are one string spelled two ways. A desktop tile has no
    /// descriptor to hand, so it is spelled this way here, and everything in this section that
    /// asks the question goes through this one property rather than writing the comparison twice.
    private func isShowing(_ display: SpaceDisplay) -> Bool {
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
    private func namesScreen(_ info: SpaceInfo, _ display: SpaceDisplay) -> Bool {
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
    private func desktopTile(
        _ display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor, showsScreenName: Bool
    ) -> some View {
        let showing = isShowing(display)
        let isCurrent = index == display.current
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
                Self.tileBox {
                    ColorPalette.surface
                        .overlay {
                            if let data = display.preview(for: index)?.jpegData,
                               let image = UIImage(data: data) {
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
    private func chooseDesktopForMosaic(
        display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor
    ) {
        let isPicked = picked.contains { $0.source == screen.source }

        // Tapping the desktop the screen is already on, when that screen is already in, is the
        // way back out. Every other tap moves the screen, and a tap that moved it to where it
        // already is would be a tap that did nothing at all.
        if isPicked, index == display.current {
            withAnimation(Motion.morph) { toggle(screen) }
            return
        }

        model.send(.switchToSpace(display: display.displayID, index: index))
        if !isPicked {
            withAnimation(Motion.morph) { toggle(screen) }
        }
    }

    /// What a desktop tile is called out loud.
    ///
    /// The screen's name comes first when there is more than one screen, because the chip above
    /// the row is a visual grouping and a screen reader does not get one: a list of "Desktop 1,
    /// Desktop 2, Desktop 1" is three tiles with no way to tell which screen the last one is on.
    private func spokenDesktop(
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
    private func switchToDesktop(display: SpaceDisplay, index: Int) {
        model.send(.switchToSpace(display: display.displayID, index: index))

        let source = CaptureSource.display(display.displayID)
        if model.activeSourceID != source.stableID {
            // Through the model rather than `send`, so the choice is recorded as well as made.
            // The raw send moved the host without moving `activeSourceID`, so the next tap back
            // to a display already named there looked like no move at all and sent nothing.
            model.selectSource(source)
        }
        // Even when no source change was needed: the tap was still a choice, and the panel gets
        // out of the way for all of them or none.
        onSelect()
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

    /// One application: what it is, and every window it is showing.
    ///
    /// The heading is the application itself and is a control — tapping it captures the whole
    /// application, every window composited, which is what the separate Applications list used
    /// to offer. The tiles under it are that application's windows, one each. So the two things a
    /// person can want are one above the other: "this whole application" and "that one window of
    /// it", with nothing to work out about which belongs to what.
    ///
    /// A heading with no application row behind it is not tappable — see
    /// ``SourceGrouping/applicationGroups(applications:windows:)`` for the catalogue shape that
    /// produces one. Its windows are still offered, which is the point.
    @ViewBuilder
    private func applicationSection(_ group: ApplicationGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let application = group.application {
                Button { choose(application) } label: {
                    applicationHeading(group)
                }
                .buttonStyle(RailButtonStyle(scale: 0.97))
                .accessibilityLabel(spoken(application))
            } else {
                applicationHeading(group)
            }

            LazyVGrid(columns: Self.previewColumns, alignment: .leading, spacing: Self.tileGap) {
                ForEach(group.windows) { previewTile($0, fallbackIcon: "macwindow") }
            }
        }
    }

    /// An application's name, its icon, and how many windows it is showing.
    ///
    /// **Marked on the same terms as a tile**, because a heading is one too: in the accumulating
    /// mode tapping it picks the whole application, and a heading that took the tap without
    /// showing that it had would be the one control in the panel with no answer.
    private func applicationHeading(_ group: ApplicationGroup) -> some View {
        let placed = group.application.map { placement(of: $0) }
        let marked = placed?.marked ?? false

        return HStack(spacing: 8) {
            ApplicationIcon(data: group.iconPNGData, fallback: "app", size: 22)
            Text(group.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(marked ? ColorPalette.accent : ColorPalette.ink)
                .lineLimit(1)
            if marked, placed?.place == nil {
                // The ordinary pick, where the mark says which source the phone is showing. In
                // the accumulating mode the number says it instead — see below — and the two are
                // never drawn together.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ColorPalette.accent)
            }
            if let place = placed?.place {
                Text("\(place)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(width: 16, height: 16)
                    .background(ColorPalette.accent, in: Circle())
                    .transition(Self.badge)
            }
            Spacer(minLength: 8)
            Text(group.windows.count == 1 ? "1 window" : "\(group.windows.count) windows")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// The groups the query leaves showing.
    ///
    /// **A window match keeps its application's heading**, so a search finds a window without
    /// stranding it under a name nobody typed — and a heading match keeps every window under it,
    /// because somebody who typed "Safari" is asking about Safari rather than about the one window
    /// whose title happens to contain it.
    private var filteredGroups: [ApplicationGroup] {
        let catalog = model.catalog
        let groups = SourceGrouping.applicationGroups(
            applications: catalog?.applications ?? [],
            windows: catalog?.windows ?? []
        )
        guard !query.isEmpty else { return groups }

        return groups.compactMap { group in
            if group.title.localizedStandardContains(query) { return group }
            let windows = group.windows.filter {
                $0.title.localizedStandardContains(query)
                    || ($0.subtitle?.localizedStandardContains(query) ?? false)
            }
            guard !windows.isEmpty else { return nil }
            return group.narrowing(to: windows)
        }
    }

    /// The applications installed on the Mac but not running, as icons.
    ///
    /// The same grid as the running ones and deliberately so: a name in this list becomes a row in
    /// the one above the moment it is opened, and two arrangements would make that look like the
    /// entry moved rather than started. What differs is the tap — one switches a source, this one
    /// launches an application — and the sentence under the grid saying so.
    @ViewBuilder
    private var installedGrid: some View {
        let installed = filteredInstalled
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Installed on your Mac")
                LazyVGrid(columns: Self.iconColumns, alignment: .leading, spacing: Self.iconGap) {
                    ForEach(installed) { application in
                        Button {
                            model.launchApplication(application)
                            onSelect()
                        } label: {
                            VStack(spacing: 6) {
                                ApplicationIcon(
                                    data: application.iconPNGData,
                                    fallback: "app.dashed",
                                    size: Self.iconSize
                                )
                                Text(application.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(ColorPalette.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.94))
                        .accessibilityLabel(application.title)
                    }
                }
                Text("Not running yet. Choosing one opens it on the Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a tile has to draw about its source: whether it is marked, and where it sits in an
    /// arrangement being built.
    ///
    /// **One mark per mode, never two.** In the ordinary pick the accent says which source the
    /// phone is showing, which is what ``desktopTile(_:index:showsScreenName:)`` means by it too.
    /// In the accumulating one the same accent says which tiles have been picked, and the badge
    /// says where each of them landed — the arrangement is filled in reading order, so that number is the tile's place in
    /// the finished picture. Both at once would be one mark meaning two things.
    private func placement(
        of descriptor: CaptureSourceDescriptor
    ) -> (marked: Bool, isLive: Bool, place: Int?) {
        let isLive = !buildingMosaic && descriptor.id == model.activeSourceID
        let place = buildingMosaic
            ? picked.firstIndex { $0.source == descriptor.source }.map { $0 + 1 }
            : nil
        return (isLive || place != nil, isLive, place)
    }

    private func choose(_ descriptor: CaptureSourceDescriptor) {
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
    private func placeBadge(_ place: Int?) -> some View {
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
    private static let badge = AnyTransition.scale(scale: 0.4).combined(with: .opacity)

    private func caption(
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

    private func spoken(_ descriptor: CaptureSourceDescriptor) -> String {
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
    private static var previewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: tileGap)]
    }

    private static var iconColumns: [GridItem] {
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
    private static let tileMinimumWidth: CGFloat = 156
    private static let tileGap: CGFloat = 8

    /// The shape a tile is drawn at when there is no size to take one from: a source the Mac has
    /// reported nothing about. Every other tile is its own picture's shape. See ``tileShape(_:)``.
    private static let tileAspect: CGFloat = 16.0 / 10.0

    /// The box a tile is drawn inside: as wide as its cell, and no taller than a 16:10 tile.
    ///
    /// **Invisible, and only ever a bound.** The picture inside takes its own shape, as large as
    /// this allows and no larger, so a portrait window comes out as a narrow tile rather than a
    /// tall one and a wide one fills the width without being stretched. It is also what makes a
    /// row of differently shaped tiles a row: every tile is measured against the same box rather
    /// than against its neighbours, so the names under them stay on one line.
    private static func tileBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
    private static let tileShapeBounds: ClosedRange<CGFloat> = 0.4...2.5

    /// The shape a tile for this source is drawn at: the picture's own.
    ///
    /// The thumbnail is asked first because it is the thing that gets drawn, and a box that
    /// disagrees with its picture is a box with something cropped off it. A source with no picture
    /// yet falls back to the size the Mac reports, which is that picture's shape, so a tile does
    /// not change shape when the picture lands.
    private static func tileShape(for descriptor: CaptureSourceDescriptor) -> CGFloat {
        guard let thumbnail = descriptor.thumbnail else { return tileShape(descriptor.pixelSize) }
        return tileShape(CGSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
    }

    /// One desktop's tile shape: that desktop's own picture, or the screen's shape without one.
    ///
    /// The second half is what keeps a desktop tile from resizing when its photograph is taken,
    /// and every desktop of a screen shares a shape, so the row is one shape rather than several.
    private func desktopShape(_ display: SpaceDisplay, index: Int) -> CGFloat {
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
    private static func tileShape(_ size: CGSize) -> CGFloat {
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
    private static let tileGrowth: CGFloat = 1.045

    /// The room the panel leaves inside its edges for a tile that has grown.
    ///
    /// **A scaled tile is wider than the cell it sits in, and a scroll view clips at its own
    /// bounds.** Half of ``tileGrowth`` comes off each side, and on the widest phone a grid of two
    /// columns gives a tile about 190 points, so it grows 4.3 points each way; six leaves that a
    /// little to spare. Without it the first and last tile of every row lost the ends of their
    /// border, which is a ring cut open rather than the mark of the one being watched.
    private static let tileRoom: CGFloat = 6

    /// The size of a Home Screen icon, which is what this grid is quoting.
    ///
    /// **Close to the width of a column, and that is the number that matters.** An adaptive grid
    /// gives every cell at least ``iconMinimumWidth`` and then spreads the leftover width evenly
    /// between them, so a small icon in a wide cell is not a small icon — it is the same icon with
    /// a gutter either side of it, and a row of those reads as a grid with something missing
    /// rather than as a grid. 74 in a cell that comes out around 86 leaves the few points a
    /// Home Screen leaves and no more.
    private static let iconSize: CGFloat = 74
    /// The corner `ApplicationIcon` derives from ``iconSize``, needed here for the mark behind it.
    private static let iconCorner: CGFloat = iconSize * (11.0 / 42.0)
    /// Just the icon and its gutter. Anything more and the grid spends its leftover width on gaps
    /// it does not need, which is exactly the state this number is here to prevent.
    private static let iconMinimumWidth: CGFloat = iconSize + 8
    private static let iconGap: CGFloat = 8

    /// Adds or removes one source from the arrangement being built.
    ///
    /// The cap is enforced here rather than by greying rows out: a row that cannot be added is
    /// a row that looks broken, and the honest answer to "why not" is that the Mac is already
    /// capturing as many as it will. Picking past it replaces nothing, it simply does not add.
    private func toggle(_ descriptor: CaptureSourceDescriptor) {
        if let index = picked.firstIndex(where: { $0.source == descriptor.source }) {
            picked.remove(at: index)
        } else if picked.count < MosaicLayout.maximumTileCount {
            picked.append(descriptor)
        }
    }

    private var filteredInstalled: [InstalledApplicationDescriptor] {
        let applications = model.catalog?.installedApplicationsNotRunning ?? []
        guard !query.isEmpty else { return applications }
        return applications.filter { $0.title.localizedStandardContains(query) }
    }

    private func filtered(_ sources: [CaptureSourceDescriptor]) -> [CaptureSourceDescriptor] {
        guard !query.isEmpty else { return sources }
        return sources.filter {
            $0.title.localizedStandardContains(query)
                || ($0.subtitle?.localizedStandardContains(query) ?? false)
        }
    }
}

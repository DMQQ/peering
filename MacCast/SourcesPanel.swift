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
                    previewGrid("Displays", catalog.displays, fallbackIcon: "display")
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

    /// The arrangement that is on screen, as a list that can be rearranged.
    ///
    /// **A row per tile, because the order is the picture.** Moving a source up this list moves
    /// it up the mosaic, so the arrangement is edited by editing a list rather than by dragging
    /// over live video — which is the same control for a thumb, works with VoiceOver, and needs
    /// no geometry at all. Sizes are what a freeform editor would add; positions are already
    /// The way back into the picker, once there is an arrangement.
    ///
    /// **Everything else this block used to hold is gone.** It was a numbered list of the tiles
    /// with a size stepper, up and down arrows and a remove button on each row — seven controls
    /// per tile, none of which said anything the picture does not already say. What is left is the
    /// one thing a list can do that a picture cannot: get you back to the picker to add or remove
    /// a window. Reordering is a hold on the tile itself, where the arrangement is.
    @ViewBuilder
    private var mosaicEdit: some View {
        VStack(alignment: .leading, spacing: 8) {
            // **The way back, and it is not in the pill.** Leaving an arrangement by tapping one
            // of its windows used to leave a chip in the status pill that returned to it; that
            // chip is gone, and without this there was no way back at all. It belongs here rather
            // than in the pill for the same reason the rest of this panel exists: choosing what
            // the picture shows is what this panel is for, and the arrangement is one of the
            // things it can show.
            //
            // Drawn only when the arrangement is *not* the picture. While it is, the heading
            // below already says so, and a button that goes where you already are is the "button
            // that goes nowhere" this app refuses everywhere else.
            if !model.isShowingMosaic {
                Button {
                    withAnimation(Motion.settle) { model.returnToMosaic() }
                    onSelect()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.split.2x2")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back to the mosaic")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text("\(model.mosaicChoicesList.count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(ColorPalette.onInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(ColorPalette.accent, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(RailButtonStyle(scale: 0.97))
                .accessibilityLabel("Back to the mosaic")
            }

            Button {
                withAnimation(Motion.settle) {
                    picked = model.mosaicChoicesList.compactMap { model.catalog?.descriptor(for: $0.source) }
                    buildingMosaic = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x2")
                        .font(.system(size: 13, weight: .medium))
                    Text("Add or remove windows")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                }
                .foregroundStyle(ColorPalette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ColorPalette.accent.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(RailButtonStyle(scale: 0.97))
        }
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
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A section of the sources that are a *place*: displays and windows, as pictures.
    ///
    /// **The panel's four sections are two kinds of thing, and they are drawn two ways.** A
    /// display and a window are somewhere you are looking, and the question somebody opens this
    /// panel with is "which one had the thing I was on it" — which only a picture answers, because
    /// every Mac's windows are a different arrangement of the same few greys. An application and
    /// an application that is not running yet are identities: its icon says which one it is in a
    /// way a photograph of one of its windows does not, since the window may be showing anything.
    ///
    /// Both grids are the same in both modes. Choosing one source and assembling a mosaic are the
    /// same act with one difference — the tapping accumulates rather than switches — and a second
    /// arrangement of the same list is the one that falls behind the day a window opens.
    @ViewBuilder
    private func previewGrid(
        _ title: String, _ descriptors: [CaptureSourceDescriptor], fallbackIcon: String
    ) -> some View {
        let matches = filtered(descriptors)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title)
                LazyVGrid(columns: Self.previewColumns, alignment: .leading, spacing: Self.tileGap) {
                    ForEach(matches) { previewTile($0, fallbackIcon: fallbackIcon) }
                }
            }
        }
    }

    /// One display or window, as a picture with its name under it.
    private func previewTile(
        _ descriptor: CaptureSourceDescriptor, fallbackIcon: String
    ) -> some View {
        let placed = placement(of: descriptor)

        return Button {
            choose(descriptor)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ColorPalette.surface)

                    if let thumbnail = descriptor.thumbnail,
                       let image = UIImage(data: thumbnail.jpegData) {
                        Image(uiImage: image)
                            .resizable()
                            // Filled rather than fitted, so every tile is the same shape and the
                            // grid stays a grid. A window is whatever shape the user left it, and
                            // letting each tile take its own would be a mosaic of pictures rather
                            // than a row of cells.
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // What the tile can honestly show before there is a picture, and this is
                        // an ordinary state rather than a failure: the host takes these when it is
                        // asked and not before, and a window that is not on the desktop this Mac
                        // is showing has no picture to take at all. See the handover on
                        // `SCScreenshotManager` photographing only what is on screen.
                        Image(systemName: fallbackIcon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(Self.tileAspect, contentMode: .fit)
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
                .overlay(alignment: .topTrailing) { placeBadge(placed.place) }

                caption(descriptor, isLive: placed.isLive)
            }
        }
        // **A tile that has just become the picture steps forward and stays there.** Tapping a
        // source used to change the accent edge and nothing else, which is a mark appearing on a
        // control the user has already finished looking at — the face of the thing they are now
        // watching should be the part that moves. It is the only movement in either grid, and it
        // is small on purpose: a quarter of the gutter either side, so a tile that grows into
        // the gap reads as arriving rather than as a grid that has gone ragged.
        .scaleEffect(placed.isLive ? 1.045 : 1)
        .animation(Motion.settle, value: placed.isLive)
        .buttonStyle(RailButtonStyle(scale: 0.94))
        // The picture is the point of the tile and carries no text of its own, so the label is
        // what a screen reader announces instead of a wall of unlabelled images.
        .accessibilityLabel(spoken(descriptor))
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
    /// phone is showing, which is what ``DesktopsPanel`` means by it. In the accumulating one the
    /// same accent says which tiles have been picked, and the badge says where each of them
    /// landed — the arrangement is filled in reading order, so that number is the tile's place in
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
    /// hanging off the edge of another. See ``DesktopsPanel/horizontalInset`` for the day that
    /// happened.
    private static var previewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: tileGap)]
    }

    private static var iconColumns: [GridItem] {
        [GridItem(.adaptive(minimum: iconMinimumWidth), spacing: iconGap)]
    }

    private static let tileMinimumWidth: CGFloat = 104
    private static let tileGap: CGFloat = 8
    private static let tileAspect: CGFloat = 16.0 / 10.0

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

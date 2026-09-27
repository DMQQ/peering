import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The shape a virtual display is made at when the phone asks for one with one tap.
///
/// A single fixed shape rather than a picker of sizes and starting orientations: choosing a
/// panel size before you have even seen it is a decision nobody asked to make, and the size and
/// orientation picker that used to sit in front of this row was the single most-skipped step in
/// this feature, tapped past rather than filled in. A real iPhone panel size, the same one
/// ``VirtualDisplay/phoneShaped`` defaults to, landscape — because a virtual display is worked at
/// like a monitor, not held like a phone.
enum VirtualDisplaySizePreset {
    static let portraitWidth = 1290
    static let portraitHeight = 2796
}

/// A desktop this phone has asked the Mac to show, while the Mac's own list has yet to say so.
///
/// See ``SourcesPanel/pendingDesktop`` for why the mark cannot wait for the answer.
struct PendingDesktop: Equatable {
    let display: UInt32
    let index: Int
}

/// Thumbnails that have already been decoded, so a body pass is not a JPEG decode per tile.
///
/// Guarded by the bytes rather than by the source alone, because a Mac that sends new pictures for the
/// same windows has to have them drawn. Comparing a few kilobytes beats decoding them, and beats the
/// fresh `UIImage` per pass that also defeated SwiftUI's own diffing.
///
/// A reference type so it can be held in `@State` and written from the body, which is only sound
/// because it answers the same picture the decode would.
@MainActor
final class ThumbnailImages {
    var entries: [String: (data: Data, image: UIImage)] = [:]

    func image(for key: String, data: Data) -> UIImage? {
        if let entry = entries[key], entry.data == data { return entry.image }
        guard let image = UIImage(data: data) else {
            entries.removeValue(forKey: key)
            return nil
        }
        entries[key] = (data, image)
        return image
    }
}

/// What the Mac can be made to share, as a floating panel.
///
/// The same list the sheet used to hold, rebuilt for a panel instead of a `List`. A `List` brings
/// its own backgrounds, separators and inset behaviour, none of which survive being put on top of
/// live video inside a sheet of glass — and the panel was already the shape every other control
/// on this screen uses. Search stays: a Mac with twenty running applications and a hundred
/// installed ones needs it more here than it did full-screen, not less.
struct SourcesPanel: View {
    @Environment(SessionModel.self) var model

    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// Called once the user has picked a source or opened an application, so the caller can put the
    /// panel away — see the setting it consults.
    var onSelect: () -> Void = {}

    /// Returns to the arrangement through the screen's picture animation.
    var onReturnToMosaic: () -> Void = {}

    /// Decoded tile pictures, kept for as long as the panel is open. See ``ThumbnailImages``.
    @State var thumbnails = ThumbnailImages()
    /// How wide one cell of the picture grid came out, measured from the first tile that lays out.
    ///
    /// The grid is adaptive, so the number is the layout's rather than a constant, and a title that
    /// has to be clipped to its own picture cannot be told how much without it. See
    /// ``captionWidth(shape:)``.
    @State var tileCellWidth: CGFloat = 0
    /// How wide one column of the installed-apps grid came out, so the icons can fill it.
    @State var iconCellWidth: CGFloat = 0

    @State var query = ""

    /// The window tile showing its title-bar buttons after a long press, if any.
    @State var windowControlsFor: CaptureSourceDescriptor.ID?
    /// When those buttons appeared, so the tap that ends the long press does not also pick the tile.
    @State var windowControlsShownAt = Date.distantPast

    /// Whether the panel is picking several sources rather than one.
    ///
    /// **A mode rather than a second panel.** Choosing a mosaic is the same act as choosing a
    /// source — the same list, the same rows — with one difference: the tapping accumulates
    /// instead of switching. A separate picker would be the same list twice, and the second one
    /// would be the one that falls behind when a window opens.
    @State var buildingMosaic = false

    /// What has been picked, in the order it was picked. The order is the arrangement: the grid
    /// is filled in reading order, so a tile's place is the place it was chosen in.
    @State var picked: [CaptureSourceDescriptor] = []

    /// The desktop this phone has just asked the Mac for, until the Mac's list agrees.
    ///
    /// Which desktop a screen is on is the Mac's to say, and it says it in the catalogue, which is
    /// coalesced: up to three seconds in which the tile the user just tapped is still drawn as the
    /// desktop they left, which reads as a tap that did not take. Taken at the tap instead, and
    /// given up when the Mac says something new or when this gives up waiting. See
    /// ``askForDesktop(_:index:)``.
    @State var pendingDesktop: PendingDesktop?

    /// The managed display an alert is asking a new name for, or `nil` when none is.
    @State var renameVirtualDisplayTarget: CaptureSourceDescriptor?
    @State var renameVirtualDisplayDraft = ""

    /// Whether a tap on ``addVirtualDisplayTile(height:)`` is still waiting on the Mac.
    ///
    /// Making a display is not instant — the window server takes up to a few seconds, and the
    /// host does not answer this command directly, only by the catalogue eventually growing a
    /// new row. Without this, a tap that had already landed looked exactly like one that had not,
    /// which is what taught a real person to tap it four more times.
    @State var isAddingVirtualDisplay = false
    /// The managed displays a tap on their remove button is still waiting on, by descriptor ID.
    /// A set rather than one flag, because more than one may be mid-removal at once.
    @State var pendingVirtualDisplayRemovalIDs: Set<String> = []

    /// How long a pending add or remove is trusted before this panel gives up waiting and lets
    /// the control be pressed again. Longer than the host's own confirmation retry (twelve tries,
    /// half a second apart — see ``HostModel/confirmManagedDisplayThroughCatalogue(_:)``), so an
    /// honest failure is reported by the Mac's own activity log before this spinner gives up on
    /// it and invites a second attempt on top of the first.
    static let virtualDisplayPendingTimeout: Duration = .seconds(7)

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
                    // Virtual displays first: below the screens they were easy to miss.
                    if !buildingMosaic { virtualDisplaysSection }
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
        // The Mac's own answer to a switch, whatever it says: a list still reporting the desktop the
        // user left is a switch the window server refused, and the mark belongs back where it was.
        // See ``pendingDesktop``.
        //
        // **Which desktop each display is on, and nothing else about the catalogue.** This used to
        // watch the whole of `spaceInfo`, and that value carries the previews too: a preview landing
        // for the *other* display changed it, dropped the optimism, and left the tile the user had
        // just tapped drawn as the desktop they left — the exact flicker this was written to stop,
        // arriving on its own timer every couple of seconds.
        .onChange(of: model.catalog?.spaceInfo?.displays.map(\.current)) { _, _ in
            pendingDesktop = nil
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if buildingMosaic { mosaicPicker }
        }
        .padding(10)
        .alert("Rename display", isPresented: Binding(
            get: { renameVirtualDisplayTarget != nil },
            set: { if !$0 { renameVirtualDisplayTarget = nil } }
        )) {
            TextField("Name", text: $renameVirtualDisplayDraft)
            Button("Save") {
                let name = renameVirtualDisplayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if case .display(let id) = renameVirtualDisplayTarget?.source, !name.isEmpty {
                    model.send(.renameVirtualDisplay(displayID: id, name: name))
                }
                renameVirtualDisplayTarget = nil
            }
            Button("Cancel", role: .cancel) { renameVirtualDisplayTarget = nil }
        }
    }

    var searchField: some View {
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
    var mosaicEntry: some View {
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
}

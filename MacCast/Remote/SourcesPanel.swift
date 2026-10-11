import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// A single fixed shape: the size and orientation picker that preceded it was the most-skipped step. A real iPhone panel size, landscape, because a virtual display is worked at like a monitor.
enum VirtualDisplaySizePreset {
    static let portraitWidth = 1290
    static let portraitHeight = 2796
}

/// A desktop this phone has asked the Mac to show, while the Mac's own list has yet to say so.
struct PendingDesktop: Equatable {
    let display: UInt32
    let index: Int
}

/// Guarded by the bytes: a Mac that sends new pictures for the same windows must have them drawn, and comparing kilobytes beats decoding them.
/// A reference type so it can be held in `@State` and written from the body, sound because it answers what the decode would.
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

/// A panel, not a `List`, which brings backgrounds, separators and insets that do not survive on live video.
struct SourcesPanel: View {
    @Environment(SessionModel.self) var model

    @Binding var chromeFrames: [ChromeRegion: CGRect]

    var onSelect: () -> Void = {}

    var onReturnToMosaic: () -> Void = {}

    @State var thumbnails = ThumbnailImages()
    /// The grid is adaptive, so the width is the layout's, and a title clipped to its picture needs it.
    @State var tileCellWidth: CGFloat = 0
    @State var iconCellWidth: CGFloat = 0

    @State var query = ""

    @State var windowControlsFor: CaptureSourceDescriptor.ID?
    /// When those buttons appeared, so the tap that ends the long press does not also pick the tile.
    @State var windowControlsShownAt = Date.distantPast

    /// A mode rather than a second panel: the same list with accumulating taps, and a second picker would be the copy that falls behind.
    @State var buildingMosaic = false

    /// The order is the arrangement: the grid fills in reading order.
    @State var picked: [CaptureSourceDescriptor] = []

    /// The Mac's catalogue is coalesced, up to three seconds in which the tapped tile is still drawn as the desktop left, which reads as a tap that did not take. Taken at the tap, given up when the Mac says something new or this gives up waiting.
    @State var pendingDesktop: PendingDesktop?

    @State var renameVirtualDisplayTarget: CaptureSourceDescriptor?
    @State var renameVirtualDisplayDraft = ""

    /// Making a display takes the window server up to a few seconds and the host answers only by the catalogue growing a row; without this a landed tap looked like one that had not, and a real person tapped four more times.
    @State var isAddingVirtualDisplay = false
    /// A set because more than one may be mid-removal at once.
    @State var pendingVirtualDisplayRemovalIDs: Set<String> = []

    /// Longer than the host's confirmation retry (twelve tries, half a second apart, see `confirmManagedDisplayThroughCatalogue(_:)`), so an honest failure is reported before this gives up and invites a second attempt.
    static let virtualDisplayPendingTimeout: Duration = .seconds(7)

    var body: some View {
        // Everything scrolls, only the picking controls are pinned: with a search field and mosaic block above the scroll view, landscape left about 370 points of panel with 250 of them taken, too short to show a row. The pinned pair ends the mode and must be reachable from anywhere in the list.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                searchField

                // Two arrangements of one slot cross-fade: the state is written inside `withAnimation` at each place that moves it.
                if !buildingMosaic {
                    if model.mosaicChoicesList.isEmpty { mosaicEntry } else { mosaicEdit }
                }

                if let catalog = model.catalog, !catalog.all.isEmpty {
                    // Virtual displays first: below the screens they were easy to miss.
                    if !buildingMosaic { virtualDisplaysSection }
                    screensSection(catalog.displays)
                    // One section per application with its windows under it: two flat lists of different things make finding your browser a matter of reading both. See ``SourceGrouping``.
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
            // Inside the scroll view, because its bounds clip a tile that has grown past its cell.
            .padding(Self.tileRoom)
        }
        // The Mac's own answer to a switch, whatever it says: a list still reporting the desktop the user left is a refused switch.
        // Watches only which desktop each display is on: watching all of `spaceInfo` meant a preview for the other display dropped the optimism and flickered.
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

    /// Two refusals: a plan without the mosaic draws the row dimmed with the badge and the paywall behind the tap; a Mac that does not know the request gets no row, since an older host cannot decode the command.
    @ViewBuilder
    var mosaicEntry: some View {
        if model.hostSupportsMosaic {
            Button {
                // Animated rather than assigned: this swaps three whole sections for another arrangement.
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

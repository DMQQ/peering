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
        VStack(alignment: .leading, spacing: 10) {
            searchField

            if buildingMosaic {
                mosaicPicker
            } else if !model.mosaicChoicesList.isEmpty {
                mosaicArrangement
            } else {
                mosaicEntry
            }

            if let catalog = model.catalog, !catalog.all.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Displays", catalog.displays, fallbackIcon: "display")
                        applicationsGrid(catalog.applications)
                        section("Windows", catalog.windows, fallbackIcon: "macwindow")
                        if !buildingMosaic { installedSection }
                    }
                }
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
                    buildingMosaic = true
                    picked = []
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
    /// here.
    @ViewBuilder
    private var mosaicArrangement: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("This mosaic")

            ForEach(Array(model.mosaicChoicesList.enumerated()), id: \.offset) { index, choice in
                HStack(spacing: 10) {
                    // The number is the tile's place in the grid, which is the thing being
                    // changed, rather than a decorative index.
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(ColorPalette.accent)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(ColorPalette.accent, lineWidth: 1.5))

                    // The catalogue's own name for it, and a plain word when there is none: a
                    // window that has closed leaves a tile behind, and a row that went blank
                    // would be the one thing in this list with nothing to act on.
                    Text(model.catalog?.descriptor(for: choice.source)?.title ?? "A window")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // **The size control, and it is two buttons rather than a drag.** How much
                    // of the picture a tile gets is the one thing about an arrangement that
                    // cannot be read off a list, so the row shows what it is set to ("2×") and
                    // steps it: bigger and smaller are unambiguous in a way a handle on live
                    // video is not, and both are reachable with a thumb on the edge of a phone.
                    Button {
                        model.stepMosaicTileSize(at: index, by: -1)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(choice.weight <= MosaicChoice.minimumWeight)
                    .opacity(choice.weight <= MosaicChoice.minimumWeight ? 0.3 : 1)

                    Text("\(choice.weight)×")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(choice.weight > 1 ? ColorPalette.accent : .secondary)
                        .frame(width: 22)

                    Button {
                        model.stepMosaicTileSize(at: index, by: 1)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(choice.weight >= MosaicChoice.maximumWeight)
                    .opacity(choice.weight >= MosaicChoice.maximumWeight ? 0.3 : 1)

                    // Up and down rather than a drag handle: the grid is filled in reading
                    // order, so up and down along the list *is* left to right and top to
                    // bottom across the picture, and a button says which way it will go.
                    Button {
                        model.moveMosaicTile(from: index, to: index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.3 : 1)

                    Button {
                        model.moveMosaicTile(from: index, to: index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == model.mosaicChoicesList.count - 1)
                    .opacity(index == model.mosaicChoicesList.count - 1 ? 0.3 : 1)

                    Button {
                        model.removeMosaicTile(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .rowSurface()
            }

            Button {
                picked = model.mosaicChoicesList.compactMap { model.catalog?.descriptor(for: $0.source) }
                buildingMosaic = true
            } label: {
                Text("Add or remove windows")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.accent)
            }
            .buttonStyle(.plain)
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
                Button("Cancel") {
                    buildingMosaic = false
                    picked = []
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    model.showMosaic(picked.map(\.source))
                    buildingMosaic = false
                    picked = []
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

    @ViewBuilder
    private func section(
        _ title: String,
        _ descriptors: [CaptureSourceDescriptor],
        fallbackIcon: String
    ) -> some View {
        let matches = filtered(descriptors)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title)
                ForEach(matches) { descriptor in
                    Button {
                        if buildingMosaic {
                            toggle(descriptor)
                        } else {
                            model.selectSource(descriptor)
                            onSelect()
                        }
                    } label: {
                        row(descriptor, fallbackIcon: fallbackIcon)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The running applications, as pictures.
    ///
    /// **A grid rather than a row each, and the thumbnails are the reason.** A row answers "what
    /// is this called", which the icon and the title had already answered; twenty of them is a
    /// list of twenty names. The question somebody actually opens this panel with is "which one
    /// had the thing I was looking at on it", and only a picture answers that. The shape is
    /// ``DesktopsPanel``'s, one level down: a picture in a rounded tile, a caption under it, and
    /// an edge in the accent on the one the phone is showing.
    ///
    /// **The same grid in both modes.** Choosing one source and assembling a mosaic are the same
    /// act with one difference — the tapping accumulates rather than switches — and a second
    /// arrangement of the same list is the one that falls behind the day a window opens. What
    /// the mosaic mode adds is the mark: a tile that has been picked carries its place in the
    /// arrangement, which is the same number the arrangement list and the finished mosaic show.
    @ViewBuilder
    private func applicationsGrid(_ descriptors: [CaptureSourceDescriptor]) -> some View {
        let matches = filtered(descriptors)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Applications")
                LazyVGrid(
                    // Adaptive rather than a fixed count: the panel is a fixed fraction of a
                    // phone, but the phones are not all the same width, and a count that suits
                    // one leaves a second column hanging off the edge of another. See
                    // ``DesktopsPanel/horizontalInset`` for the day that happened.
                    columns: [GridItem(.adaptive(minimum: Self.tileMinimumWidth), spacing: Self.tileGap)],
                    alignment: .leading,
                    spacing: Self.tileGap
                ) {
                    ForEach(matches) { descriptor in
                        applicationTile(descriptor)
                    }
                }
            }
        }
    }

    /// One application, as a picture with its name under it.
    private func applicationTile(_ descriptor: CaptureSourceDescriptor) -> some View {
        // **One mark per mode, never two.** In the ordinary pick the accent edge says which
        // source the phone is showing, which is what ``DesktopsPanel`` means by it and what this
        // panel's checkmarks say on the rows above and below. In the accumulating one the same
        // edge says which tiles have been picked, and the badge says where each of them landed —
        // the arrangement is filled in reading order, so that number is the tile's place in the
        // finished picture. Both at once would be one border meaning two things.
        let isLive = !buildingMosaic && descriptor.id == model.activeSourceID
        let place = buildingMosaic
            ? picked.firstIndex { $0.source == descriptor.source }.map { $0 + 1 }
            : nil
        let marked = isLive || place != nil

        return Button {
            if buildingMosaic {
                toggle(descriptor)
            } else {
                model.selectSource(descriptor)
                onSelect()
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ColorPalette.surface)

                    if let thumbnail = descriptor.thumbnail,
                       let image = UIImage(data: thumbnail.jpegData) {
                        Image(uiImage: image)
                            .resizable()
                            // Filled rather than fitted, so every tile is the same shape and
                            // the grid stays a grid. An application's windows are whatever
                            // shape the user last left them, and letting each tile take its
                            // own would be a mosaic of pictures rather than a row of cells.
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // What the tile can honestly show before there is a picture, and this
                        // is an ordinary state rather than a failure: the host takes these when
                        // it is asked and not before, so the first second after the panel opens
                        // looks like this, and a Mac too old to be asked always will. The icon
                        // is what identifies the application without one.
                        ApplicationIcon(data: descriptor.iconPNGData, fallback: "app")
                    }
                }
                .aspectRatio(Self.tileAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            marked ? ColorPalette.accent : ColorPalette.ink.opacity(0.18),
                            lineWidth: marked ? 2 : 1
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if let place {
                        Text("\(place)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(ColorPalette.onInk)
                            .frame(width: 18, height: 18)
                            .background(ColorPalette.accent, in: Circle())
                            .padding(5)
                    }
                }

                Text(descriptor.title)
                    .font(.system(size: 10, weight: isLive ? .semibold : .regular))
                    .foregroundStyle(isLive ? ColorPalette.accent : ColorPalette.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        // The picture is the point of the tile and carries no text of its own, so the label is
        // what a screen reader announces instead of twenty unlabelled images.
        .accessibilityLabel(
            [descriptor.title, descriptor.subtitle].compactMap { $0 }.joined(separator: ", ")
        )
    }

    /// The grid's own numbers.
    ///
    /// A tile wide enough for a window to be recognisable and narrow enough that three fit
    /// across the narrowest phone this runs on. The aspect is the shape a Mac window usually
    /// is, which is the one the captions and the crop are both chosen against.
    private static let tileMinimumWidth: CGFloat = 104
    private static let tileGap: CGFloat = 8
    private static let tileAspect: CGFloat = 16.0 / 10.0

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

    @ViewBuilder
    private var installedSection: some View {
        let installed = filteredInstalled
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Installed on your Mac")
                ForEach(installed) { application in
                    Button {
                        model.launchApplication(application)
                        onSelect()
                    } label: {
                        HStack(spacing: 10) {
                            ApplicationIcon(data: application.iconPNGData, fallback: "app.dashed")
                            Text(application.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("Open")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ColorPalette.accent)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .rowSurface()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Not running yet. Choosing one opens it on the Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ source: CaptureSourceDescriptor, fallbackIcon: String) -> some View {
        HStack(spacing: 10) {
            ApplicationIcon(data: source.iconPNGData, fallback: fallbackIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let subtitle = source.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if source.id == model.activeSourceID {
                // A checkmark and nothing else: tapping a row switches to it immediately, so a
                // chevron promising another screen would be a lie.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ColorPalette.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .rowSurface()
        .contentShape(Rectangle())
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

import MacCastKit
import RemoteCore
import SwiftUI

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
            } else {
                mosaicEntry
            }

            if let catalog = model.catalog, !catalog.all.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Displays", catalog.displays, fallbackIcon: "display")
                        section("Applications", catalog.applications, fallbackIcon: "app")
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

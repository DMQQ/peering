import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
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
    func applicationSection(_ group: ApplicationGroup) -> some View {
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

            // One row per application, scrolling sideways, with the + outside the scroll so it is
            // always in the same place however many windows there are.
            HStack(alignment: .top, spacing: Self.tileGap) {
                Self.tileRow {
                    ForEach(group.windows) {
                        previewTile($0, fallbackIcon: "macwindow", height: Self.packedTileHeight)
                    }
                }
                if !buildingMosaic, let bundle = group.bundleIdentifier {
                    newWindowTile(bundle)
                }
            }
        }
        // **Room above each application, over and above the stack's own gap.** A heading, its
        // windows and its count are one subject; set off by the same twelve points that separate a
        // heading from its own grid, the applications read as one long list of everything.
        .padding(.top, 8)
    }

    /// A tile after an application's windows that asks the Mac for one more.
    func newWindowTile(_ bundleIdentifier: String) -> some View {
        addTile(label: String(localized: "New window")) {
            model.send(.openNewWindow(bundleIdentifier: bundleIdentifier))
            onSelect()
        }
    }

    /// The dashed + tile at the end of a row of tiles, the same height as them.
    ///
    /// Outlined and dashed rather than filled: it is a place a tile could be, not one.
    func addTile(
        label: String, busy: Bool = false, disabled: Bool = false,
        height: CGFloat = packedTileHeight, action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ColorPalette.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .overlay {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(disabled ? .tertiary : .secondary)
                    }
                }
                .frame(width: height * 0.75, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .disabled(disabled || busy)
        .accessibilityLabel(busy ? String(localized: "\(label), in progress") : label)
    }

    /// An application's name, its icon, and how many windows it is showing.
    ///
    /// **Marked on the same terms as a tile**, because a heading is one too: in the accumulating
    /// mode tapping it picks the whole application, and a heading that took the tap without
    /// showing that it had would be the one control in the panel with no answer.
    func applicationHeading(_ group: ApplicationGroup) -> some View {
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
            Text(group.windows.count == 1 ? String(localized: "1 window") : String(localized: "\(group.windows.count) windows"))
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
    var filteredGroups: [ApplicationGroup] {
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
    var installedGrid: some View {
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
                                    // The whole column, less a few points so neighbours do not touch.
                                    size: iconCellWidth > 0 ? iconCellWidth - 4 : Self.iconSize
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
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if abs(width - iconCellWidth) > 0.5 { iconCellWidth = width }
                        }
                    }
                }
                Text("Not running yet. Choosing one opens it on the Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

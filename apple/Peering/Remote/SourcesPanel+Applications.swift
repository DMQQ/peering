import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// The heading is a control: tapping it captures the whole application, and the tiles under it are its windows.
    /// A heading with no application row behind it is not tappable, but its windows are still offered.
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

            // One row per application, scrolling sideways, with the + outside the scroll so it stays in one place.
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
        // Room above each application beyond the stack's gap: otherwise the applications read as one long list.
        .padding(.top, 8)
    }

    func newWindowTile(_ bundleIdentifier: String) -> some View {
        addTile(label: String(localized: "New window")) {
            model.send(.openNewWindow(bundleIdentifier: bundleIdentifier))
            onSelect()
        }
    }

    /// Outlined and dashed: a place a tile could be, not one.
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

    /// Marked on the same terms as a tile: in accumulating mode tapping it picks the whole application, and it must show that it took the tap.
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
                // The ordinary pick shows the mark; in accumulating mode the number does, never both.
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

    /// A window match keeps its application's heading; a heading match keeps every window, since "Safari" asks about Safari.
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

    /// Same grid as the running ones: a name here becomes a row above once opened, and a different arrangement would look like the entry moved rather than started.
    @ViewBuilder
    var installedGrid: some View {
        let installed = filteredInstalled
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "Installed on your Mac"))
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

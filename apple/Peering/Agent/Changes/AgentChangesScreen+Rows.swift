import MacCastKit
import RemoteCore
import SwiftUI

extension AgentChangesScreen {
    var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(overview.entries.isEmpty ? "No changes" : "\(overview.entries.count) changed files")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                Spacer(minLength: 8)
                DiffCounts(added: overview.added, removed: overview.removed, font: .system(size: 13, weight: .semibold, design: .monospaced))
            }
            if let message = overview.message {
                Text(verbatim: HostWireText.localized(message)).font(.caption).foregroundStyle(.secondary)
            }
            if overview.isTruncated {
                Text("This project is large, so only part of it is listed.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { cardEdge(radius: 24) }
    }

    var waiting: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("Asking your Mac").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    var modePicker: some View {
        HStack(spacing: 8) {
            modeChip("Changed", isOn: !review.showsAllFiles) { review.showsAllFiles = false }
            modeChip("All files", isOn: review.showsAllFiles) { review.showsAllFiles = true }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var list: some View {
        if review.showsAllFiles {
            let rows = overview.tree.rows(expanded: search.isEmpty ? review.expanded : overview.tree.allFolders)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Controls.divider }
                    treeRow(row)
                }
            }
        } else if overview.entries.isEmpty {
            Text(emptyMessage)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(overview.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Controls.divider }
                    NavigationLink(value: entry.path) { entryRow(entry, indent: 0, showsFolder: true) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyMessage: LocalizedStringKey {
        if !search.isEmpty { return "No files match." }
        return overview.hiddenCount > 0 ? "Everything that changed is hidden by filters." : "Nothing has changed in this folder yet."
    }

    func hiddenRow(_ count: Int) -> some View {
        AgentHiddenByFiltersRow(count: count, identifier: "changes-hidden-row") { showsFilters = true }
    }

    @ViewBuilder
    private func treeRow(_ row: AgentChangeTree.Row) -> some View {
        if row.isFolder {
            Button { withAnimation(.easeOut(duration: 0.15)) { review.toggle(folder: row.id) } } label: {
                FileEntryRow(
                    symbol: "folder",
                    name: row.name,
                    indent: row.depth,
                    chevron: row.isExpanded ? .down : .right,
                    isDimmed: !row.isChanged,
                    leadingInset: 0,
                    trailingInset: 0
                ) {
                    if row.isChanged {
                        Text(verbatim: "\(row.changedCount)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else if let entry = overview.entry(at: row.id) {
            NavigationLink(value: entry.path) { entryRow(entry, indent: row.depth, showsFolder: false) }
                .buttonStyle(.plain)
        } else {
            FileEntryRow(
                symbol: AgentFileGlyph.symbol(for: row.name),
                name: row.name,
                indent: row.depth,
                isDimmed: true,
                leadingInset: 0,
                trailingInset: 0
            )
        }
    }

    private func entryRow(_ entry: AgentChangeEntry, indent: Int, showsFolder: Bool) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        let folder = (entry.path as NSString).deletingLastPathComponent
        let commented = review.comments(in: entry.path).count
        return FileEntryRow(
            symbol: AgentFileGlyph.symbol(for: name),
            name: name,
            secondary: showsFolder && !folder.isEmpty ? Text(verbatim: folder).font(.system(size: 11, design: .monospaced)) : nil,
            indent: indent,
            leadingInset: 0,
            trailingInset: 0
        ) {
            HStack(spacing: 8) {
                if entry.editedByAgent { Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(.secondary) }
                if commented > 0 {
                    Text(verbatim: "\(commented)").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ColorPalette.accent)
                }
                DiffCounts(added: entry.added, removed: entry.removed)
                Text(verbatim: entry.marker)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
        }
    }

    private func modeChip(_ title: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? ColorPalette.onInk : .white.opacity(0.8))
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(isOn ? ColorPalette.ink : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0 : 0.16)))
        }
        .buttonStyle(.plain)
    }
}

private func cardEdge(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(
            LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
            lineWidth: 1
        )
}

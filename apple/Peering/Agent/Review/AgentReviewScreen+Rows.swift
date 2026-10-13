import PeeringKit
import RemoteCore
import SwiftUI

extension AgentReviewScreen {
    func groupSection(_ group: AgentReviewGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groupHeader(group)
            if let note = note(for: group) {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            ForEach(group.files) { file in
                fileRow(file, in: group)
            }
        }
        .opacity(group.status == .unreachable ? 0.55 : 1)
    }

    private func groupHeader(_ group: AgentReviewGroup) -> some View {
        let folder = (group.directory as NSString).lastPathComponent
        let comments = commentCount(in: group)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: group.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(verbatim: folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if comments > 0 {
                Button { send(group) } label: {
                    Label("Send \(comments)", systemImage: "paperplane")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private func note(for group: AgentReviewGroup) -> LocalizedStringKey? {
        switch group.status {
        case .current, .notRepository: nil
        case .unknown: "Not checked yet"
        case .checking: "Asking your Mac"
        case .unreachable: "Your Mac is not reachable. This is the last list it gave."
        }
    }

    private func fileRow(_ file: AgentReviewFile, in group: AgentReviewGroup) -> some View {
        let name = (file.file.path as NSString).lastPathComponent
        let folder = (file.file.path as NSString).deletingLastPathComponent
        let commented = inbox.review(for: group.chatID).comments(in: file.file.path).count
        let target = AgentReviewTarget(chatID: group.chatID, path: file.file.path)
        let selected = isSelected(target)
        return HStack(spacing: 4) {
            AgentReviewCheckbox(isSelected: selected, identifier: "review.checkbox.\(file.file.path)") {
                toggleSelection(target)
            }
            NavigationLink(value: target) {
                HStack(spacing: 8) {
                    Text(verbatim: marker(file.file.kind))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(ColorPalette.ink).lineLimit(1)
                        if !folder.isEmpty {
                            Text(verbatim: folder).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 8)
                    if commented > 0 {
                        Text(verbatim: "\(commented)").font(.system(size: 11, weight: .bold)).foregroundStyle(ColorPalette.accent)
                    }
                    if file.isReviewed {
                        Label("Reviewed", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    DiffCounts(added: file.file.added, removed: file.file.removed)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(selected ? 0.45 : 0.12)) }
        .opacity(file.isReviewed ? 0.5 : 1)
    }

    private func marker(_ kind: AgentChangeKind) -> String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .untracked: "U"
        }
    }

    func summary(_ queue: AgentReviewQueue) -> some View {
        let stats = queue.pendingStats
        return HStack(spacing: 10) {
            Text("^[\(stats.fileCount) file](inflect: true)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ColorPalette.ink)
            DiffCounts(added: stats.added, removed: stats.removed, font: .system(size: 13, weight: .semibold, design: .monospaced))
            Spacer(minLength: 0)
            selectAllToggle(queue)
        }
        .padding(.horizontal, 4)
    }

    func hiddenRow(_ count: Int) -> some View {
        AgentHiddenByFiltersRow(count: count, identifier: "review-hidden-row") { showsFilters = true }
    }
}

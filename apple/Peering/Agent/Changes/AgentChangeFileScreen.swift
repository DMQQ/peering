import PeeringKit
import RemoteCore
import SwiftUI

/// One changed file's diff, with a comment on a line or on the whole file.
struct AgentChangeFileScreen: View {
    let entry: AgentChangeEntry
    let review: AgentChangesReview

    @State var target: AgentCommentTarget?
    @State var draft = ""
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState var commentFocused: Bool
    private let reading: AgentReviewDiff

    init(entry: AgentChangeEntry, review: AgentChangesReview) {
        self.entry = entry
        self.review = review
        reading = entry.isGitDiff ? AgentReviewDiff(entry.diff ?? "") : AgentReviewDiff("")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
                ForEach(fileComments) { comment in commentCard(comment) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, target == nil ? 28 : 120)
        }
        .background(ColorPalette.backdrop)
        .navigationTitle((entry.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { begin(.file) } label: { Image(systemName: "text.bubble") }
                    .accessibilityLabel(Text("Comment on this file"))
            }
        }
        .overlay(alignment: .bottom) {
            composer.reviewBottomBackdrop()
        }
    }

    var emphasisesDiff: Bool { contrast == .increased || reduceTransparency }

    private var fileComments: [AgentReviewComment] {
        review.comments(in: entry.path).filter { $0.line == nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 10) {
                Text(kindTitle).font(.caption).foregroundStyle(.secondary)
                DiffCounts(added: entry.added, removed: entry.removed, font: .caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindTitle: LocalizedStringKey {
        switch entry.kind {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .untracked: "New, not tracked by git yet"
        case nil: "Edited by the agent"
        }
    }

    @ViewBuilder
    private var content: some View {
        if entry.isGitDiff, !reading.lines.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(reading.lines) { line in lineRow(line) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let diff = entry.diff, !entry.isGitDiff {
            AgentDiffBlock(diff: diff)
        } else {
            Text("There is no text diff to show for this file.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

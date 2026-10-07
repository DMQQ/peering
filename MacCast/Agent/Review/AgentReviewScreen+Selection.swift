import MacCastKit
import RemoteCore
import SwiftUI

extension AgentReviewScreen {
    var rejection: AgentReviewRejection {
        inbox.rejection(for: model.agentCards.filter(\.isLive), selection: selection)
    }

    func isSelected(_ target: AgentReviewTarget) -> Bool { selection.contains(target) }

    func toggleSelection(_ target: AgentReviewTarget) {
        withAnimation(Motion.settle) {
            if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
        }
    }

    func clearSelection() {
        withAnimation(Motion.settle) { selection = [] }
    }

    func selectAllToggle(_ queue: AgentReviewQueue) -> some View {
        let everything = Set(queue.selectableTargets)
        let allSelected = !everything.isEmpty && everything.isSubset(of: selection)
        return Group {
            if !everything.isEmpty {
                Button {
                    withAnimation(Motion.settle) { selection = allSelected ? [] : everything }
                } label: {
                    Text(allSelected ? "Clear" : "Select all")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review.selectAll")
            }
        }
    }

    /// Marks the selected files reviewed. Only files on screen are in the selection, so none is marked unseen.
    func markSelectedReviewed(_ queue: AgentReviewQueue) {
        for group in queue.visibleGroups {
            for file in group.files where selection.contains(AgentReviewTarget(chatID: group.chatID, path: file.file.path)) {
                inbox.setReviewed(true, file.file, in: group.chatID)
            }
        }
        clearSelection()
    }

    /// Sends each owning chat one prompt, drops the comments it carried and leaves the files unreviewed.
    func rejectSelected() {
        for item in rejection.items {
            model.sendAgentPrompt(item.prompt, to: item.chatID)
            let review = inbox.review(for: item.chatID)
            review.comments.removeAll { item.commentIDs.contains($0.id) }
        }
        clearSelection()
    }
}

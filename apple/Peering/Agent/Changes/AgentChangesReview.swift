import PeeringKit
import Observation
import SwiftUI

/// What the reviewer has done so far: which folders are open and what they have written. Kept above the file screens so a comment survives going back to the list.
@MainActor @Observable
final class AgentChangesReview {
    var comments: [AgentReviewComment] = []
    var expanded: Set<String> = []
    var showsAllFiles = false
    private(set) var hasOpenedFolders = false

    /// Opens the folders that hold a change, once: after that the reader's own choices stand.
    func openFoldersWithChanges(of tree: AgentChangeTree) {
        guard !hasOpenedFolders else { return }
        hasOpenedFolders = true
        expanded = tree.foldersWithChanges
    }

    func toggle(folder path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    func comments(in path: String) -> [AgentReviewComment] {
        comments.filter { $0.path == path }
    }

    func remove(_ comment: AgentReviewComment) {
        comments.removeAll { $0.id == comment.id }
    }
}

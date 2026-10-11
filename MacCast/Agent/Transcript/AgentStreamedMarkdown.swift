import SwiftUI

/// A reply that arrives whole (Codex and OpenCode send a finished block) shown as it would have streamed: the text catches up to what has arrived, quickly enough that a long answer never makes anyone wait for it.
struct AgentStreamedMarkdown: View {
    let text: String
    /// Called as the text grows, so the transcript can keep the end in view.
    let revealed: () -> Void

    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AgentMarkdownText(text: reduceMotion || shown >= text.count ? text : String(text.prefix(shown)))
            .task(id: text) { await reveal() }
    }

    /// Each step takes a fraction of what is left, so a short reply types out and a long one closes the gap in a second or two.
    private func reveal() async {
        guard !reduceMotion else { return }
        while shown < text.count {
            let remaining = text.count - shown
            shown += min(remaining, max(2, remaining / 24))
            revealed()
            try? await Task.sleep(for: .milliseconds(33))
            if Task.isCancelled { return }
        }
    }
}

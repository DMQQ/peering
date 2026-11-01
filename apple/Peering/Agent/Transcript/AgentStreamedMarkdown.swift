import SwiftUI

/// A reply that arrives whole (Codex and OpenCode send a finished block) shown as it would have streamed: the text catches up to what has arrived, quickly enough that a long answer never makes anyone wait for it.
struct AgentStreamedMarkdown: View {
    let text: String
    /// Called as the text grows, so the transcript can keep the end in view.
    let revealed: () -> Void
    /// How much was already on screen. Kept above this view: the row is rebuilt when it scrolls back into view, and starting from nothing typed the reply out again.
    var alreadyShown = 0
    var progressed: (Int) -> Void = { _ in }

    @State private var shown: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = shown ?? alreadyShown
        AgentMarkdownText(text: reduceMotion || count >= text.count ? text : String(text.prefix(count)))
            .task(id: text) { await reveal() }
    }

    /// Each step takes a fraction of what is left, so a short reply types out and a long one closes the gap in a second or two.
    private func reveal() async {
        guard !reduceMotion else { return }
        var count = shown ?? alreadyShown
        while count < text.count {
            let remaining = text.count - count
            count += min(remaining, max(2, remaining / 24))
            shown = count
            progressed(count)
            revealed()
            try? await Task.sleep(for: .milliseconds(33))
            if Task.isCancelled { return }
        }
    }
}

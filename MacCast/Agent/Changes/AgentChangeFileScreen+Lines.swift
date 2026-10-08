import MacCastKit
import SwiftUI

/// What a comment is about: the whole file, or one line of the diff.
enum AgentCommentTarget: Equatable {
    case file
    case line(AgentReviewDiff.Line)
}

extension AgentChangeFileScreen {
    func lineRow(_ line: AgentReviewDiff.Line) -> some View {
        let comments = review.comments(in: entry.path).filter { $0.line == lineNumber(line) && $0.side == side(line) }
        let selected = target == .line(line)
        return VStack(alignment: .leading, spacing: 0) {
            Button { begin(.line(line)) } label: { lineText(line, selected: selected) }
                .buttonStyle(.plain)
                .disabled(!line.isCommentable)
            ForEach(comments) { comment in commentCard(comment).padding(.horizontal, 8).padding(.bottom, 6) }
        }
    }

    private func lineText(_ line: AgentReviewDiff.Line, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: line.newNumber.map(String.init) ?? line.oldNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(line.kind == .removed ? 0.25 : 0.35))
                .frame(width: 30, alignment: .trailing)
            Text(verbatim: marker(line.kind))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tone(line.kind).accent ?? .white.opacity(0.3))
                .frame(width: 9, alignment: .leading)
            Text(verbatim: line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColour(line.kind))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, line.kind == .hunk ? 5 : 1.5)
        .background(rowFill(line.kind, selected: selected))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(ColorPalette.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
    }

    func commentCard(_ comment: AgentReviewComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text(verbatim: comment.text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { review.remove(comment) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(Text("Remove comment"))
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    var composer: some View {
        Group {
            if let target {
                let shape = RoundedRectangle(cornerRadius: InputBar.height / 2, style: .continuous)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: describe(target)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        .padding(.horizontal, 14)
                    HStack(alignment: .bottom, spacing: 8) {
                        InputCapsule(alignment: .bottom) {
                            TextField("Comment", text: $draft, axis: .vertical)
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .lineLimit(1...6)
                                .focused($commentFocused)
                                .padding(.vertical, 12)
                            Button { cancel() } label: {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 28, height: InputBar.height)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(Text("Cancel"))
                        }
                        .overlay { shape.strokeBorder(.white.opacity(commentFocused ? 0.3 : 0), lineWidth: 1) }
                        .animation(Motion.tap, value: commentFocused)
                        addButton
                    }
                }
                .inputBarMargins()
            }
        }
    }

    /// A labelled button, not an arrow: this is the step that keeps the comment, and it has to be seen.
    private var addButton: some View {
        let isEnabled = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: commit) {
            Label("Add", systemImage: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.4))
                .padding(.horizontal, 18)
                .frame(height: InputBar.height)
                .glassSurface(in: Capsule(), interactive: isEnabled)
                .contentShape(Capsule())
        }
        .buttonStyle(RailButtonStyle(scale: 0.95))
        .disabled(!isEnabled)
        .animation(Motion.tap, value: isEnabled)
        .accessibilityLabel(Text("Add comment"))
        .accessibilityIdentifier("review.comment.add")
    }

    func begin(_ next: AgentCommentTarget) {
        target = next
        draft = ""
        commentFocused = true
    }

    private func cancel() {
        target = nil
        draft = ""
        commentFocused = false
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !text.isEmpty else { return }
        switch target {
        case .file:
            review.comments.append(AgentReviewComment(path: entry.path, text: text))
        case .line(let line):
            review.comments.append(AgentReviewComment(
                path: entry.path, line: lineNumber(line), side: side(line), quote: line.text, text: text
            ))
        }
        cancel()
    }

    private func describe(_ target: AgentCommentTarget) -> String {
        switch target {
        case .file: entry.path
        case .line(let line): "\(entry.path):\(lineNumber(line) ?? 0)"
        }
    }

    private func lineNumber(_ line: AgentReviewDiff.Line) -> Int? {
        line.kind == .removed ? line.oldNumber : line.newNumber
    }

    private func side(_ line: AgentReviewDiff.Line) -> AgentReviewComment.Side {
        line.kind == .removed ? .old : .new
    }

    private func tone(_ kind: AgentReviewDiff.Kind) -> DiffTone {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .context, .hunk: .neutral
        }
    }

    private func marker(_ kind: AgentReviewDiff.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        case .hunk: "@"
        }
    }

    private func textColour(_ kind: AgentReviewDiff.Kind) -> Color {
        switch kind {
        case .added: .white.opacity(0.95)
        case .removed: .white.opacity(0.8)
        case .context: .white.opacity(0.7)
        case .hunk: .white.opacity(0.4)
        }
    }

    private func rowFill(_ kind: AgentReviewDiff.Kind, selected: Bool) -> Color {
        if selected { return .white.opacity(0.14) }
        switch kind {
        case .added: return DiffTone.added.tint(emphasised: emphasisesDiff)
        case .removed: return DiffTone.removed.tint(emphasised: emphasisesDiff)
        case .hunk: return .white.opacity(0.04)
        case .context: return .clear
        }
    }
}

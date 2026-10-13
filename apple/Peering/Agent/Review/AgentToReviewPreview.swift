import PeeringKit
import RemoteCore
import SwiftUI

extension AgentReviewQueue {
    /// The few files the card names, so it shows what is waiting rather than only how much.
    var pendingPreview: [AgentChangedFile] {
        Array(groups.flatMap { $0.status == .current ? $0.pendingFiles.map(\.file) : [] }.prefix(3))
    }
}

/// The card's screen: the first pending files as mono lines on the dark pane a terminal's output sits on.
struct AgentToReviewPreview: View {
    let files: [AgentChangedFile]
    let more: Int
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(files.enumerated()), id: \.element.path) { offset, file in
                HStack(spacing: 8) {
                    Text(verbatim: (file.path as NSString).lastPathComponent)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(offset == 0 ? 0.85 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    DiffCounts(added: file.added, removed: file.removed, font: .system(size: 10.5, weight: .semibold, design: .monospaced))
                }
            }
            if more > 0 {
                Text("+\(more) more")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let note {
                Text(verbatim: note)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.black.opacity(0.35))
    }
}

/// The card's outline with its text still to come: the same height as the header, so the real card replaces it without moving the page.
struct AgentToReviewPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.white.opacity(0.1)).frame(width: 84, height: 10)
                Capsule().fill(.white.opacity(0.06)).frame(width: 130, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
        }
        .accessibilityHidden(true)
    }
}

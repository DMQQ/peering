import MacCastKit
import RemoteCore
import SwiftUI

/// Hints for a mention: the folder's contents, narrowed by what has been typed. A folder keeps the mention open one level deeper; a file ends it.
struct AgentMentionHints: View {
    let query: MentionQuery
    let project: String
    let directory: RemoteDirectory?
    let isLoading: Bool
    let failure: String?
    let pick: (_ path: String, _ isFolder: Bool) -> Void

    private static let limit = 6

    private var matches: [RemoteDirectoryEntry] { query.matches(in: directory?.entries) }

    var body: some View {
        let shown = Array(matches.prefix(Self.limit))
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if let failure {
                note(failure)
            } else if shown.isEmpty {
                note(isLoading || directory == nil
                    ? String(localized: "Looking…")
                    : String(localized: "Nothing here starts with \u{201C}\(query.namePart)\u{201D}."))
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.name) { index, entry in
                    if index > 0 { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 46) }
                    row(entry)
                }
                if matches.count > shown.count {
                    Text("\(matches.count - shown.count) more, keep typing to narrow it")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(ColorPalette.backdrop, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .animation(Motion.settle, value: shown.map(\.name))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "at")
                .font(.system(size: 11, weight: .bold))
            Text(verbatim: shownFolder)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            if isLoading { ProgressView().controlSize(.mini) }
        }
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    /// Relative to the project, which is also how the agent will read the mention.
    private var shownFolder: String {
        query.folderPart.isEmpty ? String(localized: "In this project") : query.folderPart
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    private func row(_ entry: RemoteDirectoryEntry) -> some View {
        Button {
            pick(query.folderPart + entry.name, entry.isDirectory)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: entry.isDirectory ? "folder" : AgentFileGlyph.symbol(for: entry.name))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 24)
                Text(verbatim: entry.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: entry.isDirectory ? "chevron.right" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.isDirectory ? Text("Opens this folder") : Text("Mentions this file"))
    }
}

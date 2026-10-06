import RemoteCore
import SwiftUI

/// The `@path` being typed at the end of a message: the folder it points into and the start of the name inside it.
struct MentionQuery: Equatable {
    /// What follows the `@`, as typed.
    let typed: String
    /// The part up to and including the last slash, relative to the project (or absolute).
    let folderPart: String
    let namePart: String

    /// The last word of the draft, when it starts with `@`. The caret is not known to a SwiftUI field, so this is the end of the text: where a mention is nearly always being typed.
    init?(draft: String) {
        guard let range = draft.range(of: "@[^\\s@]*$", options: .regularExpression),
              range.lowerBound == draft.startIndex || draft[draft.index(before: range.lowerBound)].isWhitespace
        else { return nil }
        let typed = String(draft[range].dropFirst())
        self.typed = typed
        if let slash = typed.lastIndex(of: "/") {
            folderPart = String(typed[...slash])
            namePart = String(typed[typed.index(after: slash)...])
        } else {
            folderPart = ""
            namePart = typed
        }
    }

    /// The folder to list, on the Mac.
    func folder(in project: String) -> String {
        let base = folderPart.hasPrefix("/") ? folderPart : (project.hasSuffix("/") ? project : project + "/") + folderPart
        let trimmed = base.count > 1 && base.hasSuffix("/") ? String(base.dropLast()) : base
        return (trimmed as NSString).standardizingPath
    }

    /// What the folder holds that fits what has been typed: names starting with it first, then folders, then the rest.
    func matches(in directory: RemoteDirectory?) -> [RemoteDirectoryEntry] {
        guard let directory else { return [] }
        let showsHidden = namePart.hasPrefix(".")
        let lowered = namePart.lowercased()
        return directory.entries
            .filter { showsHidden || !$0.name.hasPrefix(".") }
            .filter { namePart.isEmpty || $0.name.localizedStandardContains(namePart) }
            .sorted { lhs, rhs in
                let leftStarts = lhs.name.lowercased().hasPrefix(lowered)
                let rightStarts = rhs.name.lowercased().hasPrefix(lowered)
                if leftStarts != rightStarts { return leftStarts }
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func replacing(in draft: String, with path: String, isFolder: Bool) -> String {
        guard let range = draft.range(of: "@[^\\s@]*$", options: .regularExpression) else { return draft }
        let escaped = path.contains(" ") ? path.replacingOccurrences(of: " ", with: "\\ ") : path
        return draft.replacingCharacters(in: range, with: "@" + escaped + (isFolder ? "/" : " "))
    }
}

/// Hints for a mention: the folder's contents, narrowed by what has been typed. A folder keeps the mention open one level deeper; a file ends it.
struct AgentMentionHints: View {
    let query: MentionQuery
    let project: String
    let directory: RemoteDirectory?
    let isLoading: Bool
    let failure: String?
    let pick: (_ path: String, _ isFolder: Bool) -> Void

    private static let limit = 6

    private var matches: [RemoteDirectoryEntry] { query.matches(in: directory) }

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

/// The same hints as one row of chips, in the place the model and permission chips are: a mention is a small thing to be offered, and the full list opens out of this row only when asked for.
struct AgentMentionChips: View {
    let query: MentionQuery
    let directory: RemoteDirectory?
    let isLoading: Bool
    @Binding var expanded: Bool
    let pick: (_ path: String, _ isFolder: Bool) -> Void

    var body: some View {
        let matches = query.matches(in: directory)
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "at")
                            .font(.system(size: 11, weight: .bold))
                        Text(verbatim: query.folderPart.isEmpty ? String(localized: "This project") : query.folderPart)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.trailing, 2)

                    if matches.isEmpty {
                        Text(isLoading || directory == nil ? "Looking…" : "No match")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(matches.prefix(24), id: \.name) { entry in
                        Button { pick(query.folderPart + entry.name, entry.isDirectory) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: entry.isDirectory ? "folder" : AgentFileGlyph.symbol(for: entry.name))
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(verbatim: entry.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 34, height: 30)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide the list" : "Show the list")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import PeeringKit
import os

extension FileBrowserPanel {
    // MARK: - The list

    @ViewBuilder
    var content: some View {
        VStack(spacing: 0) {
            changeFailureBanner
            contentBody
        }
    }

    /// Why a change did not happen, above the list rather than replacing it: unlike ``failure``, the folder is readable and the row to retry stays. Cleared by the three operations, opening a file or leaving the browser.
    @ViewBuilder
    var changeFailureBanner: some View {
        if let changeFailure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                Text(changeFailure)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ColorPalette.caution)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ColorPalette.caution.opacity(0.12))
        }
    }

    @ViewBuilder
    var contentBody: some View {
        if let failure {
            state(
                symbol: "exclamationmark.triangle",
                message: failure,
                actionTitle: String(localized: "Try again"),
                action: onReload
            )
        } else if let directory, hasVisibleEntries(directory) {
            list(directory)
        } else if isFiltering, let directory, !directory.entries.isEmpty {
            // Asked before the loading branch: a filter that matched nothing is an answer about the folder, not a wait.
            state(symbol: "magnifyingglass", message: emptyMessage(directory), detail: hiddenHint(directory))
        } else if isLoading || directory == nil {
            readingState
        } else if let directory {
            state(symbol: "folder", message: emptyMessage(directory))
        }
    }

    /// Trimmed: a filter of one space is not a filter.
    var needle: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var isFiltering: Bool { !needle.isEmpty }

    func hiddenHint(_ directory: RemoteDirectory) -> String? {
        guard !showsHidden, !hasVisibleEntries(directory) else { return nil }
        let hidden = directory.entries.filter { $0.name.hasPrefix(".") && matches($0) }
        guard !hidden.isEmpty else { return nil }
        return hidden.count == 1
            ? String(localized: "One hidden file matches. Show hidden files to see it.")
            : String(localized: "\(hidden.count) hidden files match. Show hidden files to see them.")
    }

    /// "Reading…" first, and once it has taken a while, a calm word about why: usually the Mac is waiting on a one-time macOS question that only someone at the Mac can answer.
    @ViewBuilder
    var readingState: some View {
        if waitingLongEnough, let waitingHint {
            state(symbol: "desktopcomputer", message: String(localized: "Waiting for your Mac"), detail: waitingHint)
        } else {
            state(symbol: "folder", message: String(localized: "Reading…"))
        }
    }

    func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Truncated in the middle: the count at the front and the file name at the back both matter.
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let onCancelProgress {
                Button(action: onCancelProgress) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(localized: "Cancel upload"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .bottom) { hairline }
    }

    func list(_ directory: RemoteDirectory) -> some View {
        // Filtered once for the whole list: it was drawn from three places, so computing it at each cost three passes.
        let entries = visible(directory)
        return ScrollView(.vertical, showsIndicators: false) {
            // Lazy: a listing can be two thousand rows.
            LazyVStack(spacing: 0) {
                // `..` rather than the parent's name, as a terminal calls up one level.
                if let parent {
                    upRow(parent)
                    if !entries.isEmpty { Controls.divider }
                }
                ForEach(Array(entries.enumerated()), id: \.element.name) { index, entry in
                    if index > 0 { Controls.divider }
                    row(entry)
                }
                if directory.isTruncated {
                    if !entries.isEmpty { Controls.divider }
                    Text("This folder has more in it than is shown here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    func row(_ entry: RemoteDirectoryEntry) -> some View {
        let offersRun = onRun != nil && entry.isExecutable
        // Two buttons side by side: a Button nested in another's label draws but never receives the tap, since the outer one claims the whole row.
        return HStack(spacing: 0) {
            Button {
                searchFocused = false
                onOpen(entry)
            } label: {
                FileEntryRow(
                    symbol: entry.isDirectory ? "folder" : "doc.text",
                    name: entry.name,
                    secondary: detail(for: entry),
                    chevron: .right,
                    trailingInset: offersRun ? 2 : 16
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let onDownload {
                    Button(entry.isDirectory ? "Download as zip" : "Download", systemImage: "arrow.down.circle") {
                        onDownload(entry)
                    }
                    .menuInk()
                }
                if entry.isDirectory, onUploadInto != nil {
                    Button("Upload here", systemImage: "arrow.up.circle") {
                        uploadTarget = childPath(entry.name, of: path)
                        showsImporter = true
                    }
                    .menuInk()
                    Button("Upload photos here", systemImage: "photo.on.rectangle") {
                        uploadTarget = childPath(entry.name, of: path)
                        showsPhotos = true
                    }
                    .menuInk()
                }

                if onRename != nil {
                    Button("Rename", systemImage: "character.cursor.ibeam") {
                        nameDraft = entry.name
                        pendingRename = entry
                    }
                    .menuInk()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDelete = entry
                    }
                    // `role:` colours the label and not the glyph, so a destructive item needs both (see `Theme.menuDanger`).
                    .menuDanger()
                }

                if let onRevealPath {
                    Button("Put path in command line", systemImage: "arrow.up.forward.square") {
                        onRevealPath(childPath(entry.name, of: path))
                    }
                    .menuInk()
                }
            }

            if offersRun {
                Button { pendingRun = entry } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ColorPalette.accent)
                        .frame(width: 32, height: 32)
                        .background(ColorPalette.accent.opacity(0.14), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.9))
                .padding(.trailing, 12)
                .accessibilityLabel("Run \(entry.name)")
            }
        }
    }

    func upRow(_ parent: String) -> some View {
        Button {
            searchFocused = false
            onNavigate(parent)
        } label: {
            HStack(spacing: 11) {
                Controls.icon("arrow.up.left")
                VStack(alignment: .leading, spacing: 2) {
                    Text("..")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(ColorPalette.ink)
                    Text("Up one level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var parent: String? {
        guard let path, path.hasPrefix("/"), path != floor else { return nil }
        let up = (path as NSString).deletingLastPathComponent
        return up == path ? nil : up
    }

    /// The mode bits, size and date, as `ls -l` orders them; the mode bits are terminal output so they use the terminal's face. A symlink says what it is, since its size is the length of its path. The `ls` fallback has neither mode nor size, so it gets no invented numbers.
    func detail(for entry: RemoteDirectoryEntry) -> Text {
        guard !entry.permissions.isEmpty else {
            let word = entry.isSymlink ? String(localized: "Symbolic link") : (entry.isDirectory ? String(localized: "Folder") : String(localized: "File"))
            return Text(word).font(.caption)
        }

        var parts: [String] = []
        if entry.isSymlink {
            parts.append(String(localized: "Symbolic link"))
        } else {
            // The empty file is named, not counted: every `byteCount` option answers zero as "Zero kB".
            parts.append(entry.size == 0 ? String(localized: "Zero bytes") : entry.size.formatted(.byteCount(style: .file)))
        }
        if let modified = entry.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }

        // Fonts are set on each run: a `.font` on the concatenation would lose the difference between the two faces.
        return Text(entry.permissions)
            .font(.system(size: 11, design: .monospaced))
            + Text(" · " + parts.joined(separator: " · "))
                .font(.caption)
    }

    /// Hidden means a leading dot, as the shell obeys; the Finder's hidden flag does not cross the wire. The filter goes second so it narrows what is on screen. One predicate serves the check and the list, so they cannot disagree about whether a folder looks empty.
    func shows(_ entry: RemoteDirectoryEntry) -> Bool {
        if !showsHidden, entry.name.hasPrefix(".") { return false }
        return matches(entry)
    }

    func visible(_ directory: RemoteDirectory) -> [RemoteDirectoryEntry] {
        directory.entries.filter(shows)
    }

    /// Stops at the first match: the body asks this on every pass.
    func hasVisibleEntries(_ directory: RemoteDirectory) -> Bool {
        directory.entries.contains(where: shows)
    }

    /// `localizedStandardContains`: case and accent insensitive and Finder-ordered, like the providers' sort.
    func matches(_ entry: RemoteDirectoryEntry) -> Bool {
        isFiltering ? entry.name.localizedStandardContains(needle) : true
    }

    func emptyMessage(_ directory: RemoteDirectory) -> String {
        if directory.entries.isEmpty { return String(localized: "This folder is empty.") }
        if isFiltering { return String(localized: "Nothing in this folder matches “\(needle)”.") }
        return String(localized: "Everything in this folder is hidden.")
    }

    // MARK: - Loading, empty and failed

    func state(
        symbol: String,
        message: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ColorPalette.accent)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}

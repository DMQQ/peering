import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
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

    /// Why a change did not happen, in a band above the list rather than in place of it.
    ///
    /// **The difference from ``failure`` is the whole reason this exists.** A folder that could not
    /// be read has nothing to draw, so the panel replaces the list and offers to try again; a
    /// rename that would not land left the folder perfectly readable, and covering it up would take
    /// away the row the user is about to try again on — along with their place in a long list.
    ///
    /// It cannot be dismissed by hand, and it does not need to be: every one of the three
    /// operations clears it on the way out, and so does opening a file or leaving the browser.
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
                actionTitle: "Try again",
                action: onReload
            )
        } else if let directory, hasVisibleEntries(directory) {
            list(directory)
        } else if isFiltering, let directory, !directory.entries.isEmpty {
            // Asked before the loading branch, because a filter that matched nothing is an answer
            // about the folder in hand and not a wait: a reload of a folder whose rows are all
            // filtered out would otherwise sit on "Reading…" until it arrived, to say the same
            // thing it was already saying.
            state(symbol: "magnifyingglass", message: emptyMessage(directory), detail: hiddenHint(directory))
        } else if isLoading {
            state(symbol: "folder", message: "Reading…", detail: slowReadHint)
        } else if let directory {
            state(symbol: "folder", message: emptyMessage(directory))
        } else {
            state(symbol: "folder", message: "Reading…", detail: slowReadHint)
        }
    }

    /// What is being looked for, with the spaces around it dropped — a filter of one space is not
    /// a filter, and it should not throw the folder away either.
    var needle: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the rows on screen are the ones that matched rather than the ones that are there.
    var isFiltering: Bool { !needle.isEmpty }

    /// Why a filter that the folder does not look like it has found nothing — the one case worth
    /// naming, because the answer is on the row below, in the eye.
    func hiddenHint(_ directory: RemoteDirectory) -> String? {
        guard !showsHidden, !hasVisibleEntries(directory) else { return nil }
        let hidden = directory.entries.filter { $0.name.hasPrefix(".") && matches($0) }
        guard !hidden.isEmpty else { return nil }
        return hidden.count == 1
            ? String(localized: "One hidden file matches. Show hidden files to see it.")
            : String(localized: "\(hidden.count) hidden files match. Show hidden files to see them.")
    }

    /// The hint, but only after the wait has gone on long enough to be worth explaining.
    var slowReadHint: String? {
        waitingLongEnough ? waitingHint : nil
    }

    /// The one line a running job gets, under the path bar.
    ///
    /// A spinner beside it even when the run has stopped, because the line is what the run came to
    /// and is still the most recent thing that happened in this folder — the same reason it stays
    /// at all. See ``FolderUpload``.
    func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Truncated in the middle, because both ends of this sentence carry something: the
                // count at the front and the name of the file at the back, and a tail truncation
                // would take the name every time it was long.
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .bottom) { hairline }
    }

    func list(_ directory: RemoteDirectory) -> some View {
        // Filtered once for the whole list. This is drawn from three places, and computing it at
        // each of them was three full passes over the folder per body pass.
        let entries = visible(directory)
        return ScrollView(.vertical, showsIndicators: false) {
            // Lazy, because a listing can be two thousand rows and a plain stack builds all of
            // them whether or not anyone scrolls that far.
            LazyVStack(spacing: 0) {
                // The row a shell browser would have. Written as `..` rather than as the parent's
                // name because that is what the audience reads: this panel lives in a terminal,
                // and the two dots are what a terminal has always called "up one level".
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

    /// One entry: a glyph, its name, what it is, and the way in — plus, when the file can be run,
    /// a second way that is not "in".
    ///
    /// The same row as the app's other lists — see ``SSHQuickCommandsEditor/row`` — because it is
    /// the same object: a thing with a name, a line about it, and something on the other side of
    /// the tap.
    func row(_ entry: RemoteDirectoryEntry) -> some View {
        let offersRun = onRun != nil && entry.isExecutable
        // Two buttons side by side rather than one inside the other. A `Button` nested in another
        // button's label draws, and looks right, and never receives the tap: the outer one claims
        // the whole row first. So the row is a row that *contains* two tappable things, which is
        // the only arrangement where both of them work.
        return HStack(spacing: 0) {
            Button {
                // Opening something is leaving the list, and a keyboard left up over the folder
                // that arrives next is one the user has to put away before they can see it.
                searchFocused = false
                onOpen(entry)
            } label: {
                HStack(spacing: 11) {
                    Controls.icon(entry.isDirectory ? "folder" : "doc.text")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // No font here — the two runs of it are set in two faces inside — and one
                        // line only, because a row whose second line wrapped would be a row of two
                        // heights in a list read by scanning down it.
                        detail(for: entry)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    // Pointing rather than offering to open: a tap on a file shows what is in it,
                    // and a tap on a folder goes into it. Both are "in there", so both get the
                    // same glyph.
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                // The trailing inset is shared with the run button when there is one, so the
                // chevrons of two rows next to each other still line up.
                .padding(.leading, 16)
                .padding(.trailing, offersRun ? 2 : 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if onRename != nil {
                    Button("Rename", systemImage: "character.cursor.ibeam") {
                        nameDraft = entry.name
                        pendingRename = entry
                    }
                    .menuInk()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDelete = entry
                    }
                    // `role:` colours the label and not the glyph, so a destructive item needs
                    // both or it draws a red word beside a white bin. See `Theme.menuDanger`.
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

    /// The row out of this folder, drawn as a folder row so the list keeps one shape.
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

    /// The folder one level up, or nothing when there is nowhere further up to go.
    var parent: String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let up = (path as NSString).deletingLastPathComponent
        return up == path ? nil : up
    }

    /// What a row says under the name: the mode bits, the size, and when it last changed.
    ///
    /// `ls -l`'s first and fifth columns and then the date, in that order, because that listing
    /// is what this panel is a picture of and somebody who reads one already reads the other. The
    /// mode bits are the only run on the line that is terminal output rather than app writing, so
    /// they are set in the terminal's own face — and they carry the type as their first character,
    /// which is why a folder no longer also needs the word.
    ///
    /// A symbolic link still says what it is rather than how big it is: the size of a link is the
    /// length of the path it holds — a number about the link and not about anything the user has.
    ///
    /// The one listing with neither a mode nor a size is the `ls` fallback, which answers with
    /// names and nothing else. That entry is given the word for what it is and no numbers, because
    /// a `0 bytes` and a zero date invented on this side would be this panel making them up.
    func detail(for entry: RemoteDirectoryEntry) -> Text {
        guard !entry.permissions.isEmpty else {
            let word = entry.isSymlink ? String(localized: "Symbolic link") : (entry.isDirectory ? String(localized: "Folder") : "File")
            return Text(word).font(.caption)
        }

        var parts: [String] = []
        if entry.isSymlink {
            parts.append(String(localized: "Symbolic link"))
        } else {
            // The empty file is named rather than counted, because Foundation will not: every
            // combination of `byteCount`'s options answers zero bytes with "Zero kB", which is a
            // unit for a thing that has none. This is the one row in a folder where the number is
            // the whole of what there is to say, and wrong is worse here than verbose.
            parts.append(entry.size == 0 ? String(localized: "Zero bytes") : entry.size.formatted(.byteCount(style: .file)))
        }
        if let modified = entry.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }

        // Both fonts are named here rather than by the row, because the two runs are two faces on
        // one line: a `.font` applied to the concatenation would set both and lose the difference.
        return Text(entry.permissions)
            .font(.system(size: 11, design: .monospaced))
            + Text(" · " + parts.joined(separator: " · "))
                .font(.caption)
    }

    /// The entries to show: the hidden ones dropped unless they were asked for, then the ones
    /// that match what is being looked for.
    ///
    /// A leading dot, which is the rule every Unix tool uses and the one the shell this panel
    /// belongs to already obeys. The Finder's own hidden flag is a second rule and is not part of
    /// what crosses the wire, so a folder that is hidden to the Finder and not to `ls` is listed
    /// here — which is the right answer for a terminal.
    ///
    /// The filter goes second, so it narrows what is on screen rather than reaching behind the
    /// eye. A search that quietly listed dotfiles while the toggle beside it said they were
    /// hidden would be two controls disagreeing about one list.
    /// Whether one entry is drawn: a hidden name only when hidden files are shown, and a name the
    /// filter accepts. One predicate for the check and for the list, so the two cannot disagree about
    /// whether a folder looks empty.
    func shows(_ entry: RemoteDirectoryEntry) -> Bool {
        if !showsHidden, entry.name.hasPrefix(".") { return false }
        return matches(entry)
    }

    func visible(_ directory: RemoteDirectory) -> [RemoteDirectoryEntry] {
        directory.entries.filter(shows)
    }

    /// Whether anything would be drawn, without building the list to find out: the body asks this on
    /// every pass, and this stops at the first row that matches.
    func hasVisibleEntries(_ directory: RemoteDirectory) -> Bool {
        directory.entries.contains(where: shows)
    }

    /// Whether a name is one the user is looking for.
    ///
    /// `localizedStandardContains` rather than a plain one, which is the same comparison the two
    /// providers sort by: it is insensitive to case and to accents, and it puts `file 10` where a
    /// Finder would — so what the filter keeps is in the order it was already in.
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
                    // It arrives while the user is watching the spinner, so it should look like
                    // something appearing rather than something that was always there and they
                    // somehow missed.
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

    /// The line between one band of the panel and the next, the terminal's own — see
    /// ``TerminalScreen``. Shared here by being the same one point of the same white.
    var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}

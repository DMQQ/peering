import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

// `childPath` moved to `RemoteCore`, alongside `ShellPath.quoted`, when the SSH browser turned
// out to need the same join for a different reason: resolving a symbolic link means naming the
// thing on the other end of it. The rule is unchanged and this file still calls it unqualified.

/// A folder on the Mac, as a list.
///
/// Draws what it is given and asks for nothing: every tap is a callback, and the panel holds no
/// session, no path of its own and no cache. ``TerminalPanel`` owns all of that, which is what
/// lets this be the same view for the two browsers the app is going to have — the Mac this phone
/// is casting to, and the server the SSH terminal is on — with the difference between them living
/// in whoever answers the callbacks.
///
/// The list is drawn on the terminal's own black rather than on a card, and that is deliberate.
/// This panel is not a screen of its own: it is what the terminal shows instead of its output for
/// as long as the user is looking at folders, so it keeps the terminal's shape — flat bands, a
/// rule between them, glyphs in the app's own tile — and takes only the parts of the settings
/// vocabulary that survive being put on black.
struct FileBrowserPanel: View {
    /// The folder being shown, and `nil` while the Mac's home folder is still being resolved.
    let path: String?
    /// What the Mac sent for it, if anything has arrived yet. A folder already in hand is shown
    /// while its next copy is on the way, which is what makes stepping in and back out instant.
    let directory: RemoteDirectory?
    let isLoading: Bool
    let failure: String?
    /// Whether names beginning with a dot are listed. Filtered here rather than on the Mac, so
    /// that both browsers behave the same way about it in phase two.
    let showsHidden: Bool

    /// What to say when a listing takes long enough that waiting is no longer the whole story.
    ///
    /// Supplied by whoever answers the callbacks, because only they know what a slow read means on
    /// their side. On the Mac it is almost always the system asking the user a question, and on a
    /// server it is the server or the network. `nil` says nothing, which is what a browser with no
    /// such story to tell should do.
    ///
    /// `var` rather than `let` for the default, which is a Swift rule rather than a preference: a
    /// `let` with an initial value is not part of the memberwise initialiser at all, so a call
    /// site passing one would be told it had an extra argument.
    var waitingHint: String? = nil

    /// A folder or file was tapped.
    var onOpen: (RemoteDirectoryEntry) -> Void
    /// Go to an absolute path: a breadcrumb, or the row that steps up a level.
    var onNavigate: (String) -> Void
    /// Put a path in the terminal's command line rather than opening it.
    var onRevealPath: (String) -> Void
    /// Ask for the current folder again.
    var onReload: () -> Void

    /// Send a file the user picked to the folder on screen. Absent where there is no door for it —
    /// the Mac's own browser, which cannot yet be written to at all.
    ///
    /// Optional rather than a closure that might do nothing, because the button is drawn from
    /// whether this is here: a control that appears and then silently does nothing is worse than one
    /// that was never offered.
    var onUpload: ((URL) -> Void)?

    /// Whether the current wait has lasted long enough to be explained.
    ///
    /// The Mac blocks *inside* the listing call while macOS shows a Files-and-Folders prompt, so
    /// from here a permission question and a slow disk are the same thing: a request that has not
    /// answered. There is no API that says "a prompt is on screen over there", and the honest
    /// thing is therefore a guess with a delay on it — long enough that a listing which was
    /// merely quick has already arrived, short enough that nobody sits through it twice.
    @State private var waitingLongEnough = false

    /// What the user is looking for, if they have said.
    ///
    /// Filtered here rather than asked of the machine, and for the reason the hidden-file rule is
    /// filtered here too: a folder is already in hand, and a second round trip for every letter
    /// typed would be a listing that flickers behind the keyboard. It also means both browsers
    /// narrow the same way, which they would not if one of them asked a server to.
    @State private var query = ""
    /// Whether the system's file picker is up. See ``searchField`` for the button that raises it.
    @State private var showsImporter = false

    /// A real `@FocusState`, unlike the terminal's own command field, and it is the same fact
    /// that makes that one a plain flag: this is a SwiftUI `TextField` and claims its focus
    /// through a `.focused()` modifier, so SwiftUI and UIKit agree about who is first responder.
    @FocusState private var searchFocused: Bool

    private static let slowReadInterval: Duration = .milliseconds(2500)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the thing being uploaded, not the whole Finder tree: this is one file into one
        // folder, and a picker that offers everything is a picker that makes the user work out
        // which of the options they have already found is the one that sends it.
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            onUpload?(url)
        }
        // Keyed to the wait itself, so the clock starts when a request goes out and the flag is
        // cleared the moment one comes back — including a wait that ends in a failure, which has
        // its own thing to say and should not be talked over.
        .task(id: isLoading) {
            waitingLongEnough = false
            guard isLoading else { return }
            try? await Task.sleep(for: Self.slowReadInterval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { waitingLongEnough = true }
        }
        // Looking for something is looking for it *here*. A filter left over from the last folder
        // would arrive in the new one as rows that are missing for no reason on screen — the same
        // fault as a search field that keeps its text after the thing it searched has gone.
        .onChange(of: path) { _, _ in query = "" }
    }

    // MARK: - Header

    /// Where this folder is, and what is being looked for in it.
    ///
    /// One band rather than two: they are the same two answers about the same list, and a second
    /// strip of grey above the rows is a screen with less room for the rows.
    private var header: some View {
        VStack(spacing: 0) {
            breadcrumbs
            searchField
        }
        .background(Color.white.opacity(0.05))
        // Only along the bottom. The tab strip above draws the seam under itself, and a second
        // hairline a point below that one is the fault this panel's neighbours were careful to
        // avoid — two rules where the panel is meant to read as one piece.
        .overlay(alignment: .bottom) { hairline }
    }

    /// The filter, as a field of its own rather than behind a magnifier.
    ///
    /// Always on screen, which is the whole of the decision: a control that has to be found is
    /// one that does not get used, and a folder with two hundred rows is the one place in this
    /// app where finding a name by scrolling is genuinely hopeless. It costs a row of height on
    /// a screen that has plenty of them.
    /// The filter, and the one control that puts something new into this folder.
    ///
    /// Side by side rather than the upload inside the capsule with the filter: the field is a place
    /// to type and a button in it is a glyph competing with the clear cross for the same corner,
    /// where this is a different kind of thing altogether — the only control on the panel that
    /// changes the server rather than the view.
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            filterField

            if onUpload != nil {
                Button { showsImporter = true } label: {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.9))
                .accessibilityLabel("Upload a file to this folder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Filter these names", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ColorPalette.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                // Return puts the keyboard away rather than doing nothing with it. This panel is
                // a long way inside someone else's screen and cannot add a key of its own to
                // their keyboard — the Mac panel's own Done is wired to the command field, and
                // the SSH screen has none — so the field answers for itself.
                .submitLabel(.done)
                .onSubmit { searchFocused = false }

            // Only once there is something to clear. A cross sitting over an empty field is a
            // control that does nothing, and this one would sit a few points from the field's
            // own leading edge where it reads as part of the magnifier.
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, query.isEmpty ? 11 : 5)
        .frame(height: 32)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    // MARK: - Breadcrumbs

    /// Where this folder is, as the walk that got here.
    ///
    /// Every segment is a way back to it, because on a phone the alternative is a back button
    /// pressed four times. The last one is where the user already is, so it is written rather
    /// than made tappable — a control that does nothing when pressed is worse than no control.
    private var breadcrumbs: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(segments.enumerated()), id: \.element.path) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        if index == segments.count - 1 {
                            Text(segment.title)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ColorPalette.ink)
                                .lineLimit(1)
                        } else {
                            Button { onNavigate(segment.path) } label: {
                                Text(segment.title)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            // The end of the path is where the user is, and a path deep enough to scroll is one
            // whose end is off the screen until it is brought back. The root is always where the
            // scroll starts, which is the wrong end of it every time.
            .onAppear { reader.scrollTo(segments.last?.path, anchor: .trailing) }
            .onChange(of: path) { _, _ in
                withAnimation(Motion.settle) { reader.scrollTo(segments.last?.path, anchor: .trailing) }
            }
        }
        // The path scrolls; the spinner does not. It sits outside the scroller so that a deep path
        // pushed to its end does not push the one sign that something is happening off the screen.
        .overlay(alignment: .trailing) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 14)
            }
        }
    }

    /// The path split into the folders it is made of, each with the path that reaches it.
    private var segments: [(title: String, path: String)] {
        guard let path, path.hasPrefix("/") else { return [] }
        // The root is a segment of its own and is spelt as it is spelt in a shell, so the walk
        // back out of a deep folder ends somewhere with a name everyone knows.
        var result: [(title: String, path: String)] = [("/", "/")]
        var walked = ""
        for component in path.split(separator: "/") {
            walked += "/" + component
            result.append((String(component), walked))
        }
        return result
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let failure {
            state(
                symbol: "exclamationmark.triangle",
                message: failure,
                actionTitle: "Try again",
                action: onReload
            )
        } else if let directory, !visible(directory).isEmpty {
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
    private var needle: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the rows on screen are the ones that matched rather than the ones that are there.
    private var isFiltering: Bool { !needle.isEmpty }

    /// Why a filter that the folder does not look like it has found nothing — the one case worth
    /// naming, because the answer is on the row below, in the eye.
    private func hiddenHint(_ directory: RemoteDirectory) -> String? {
        guard !showsHidden, visible(directory).isEmpty else { return nil }
        let hidden = directory.entries.filter { $0.name.hasPrefix(".") && matches($0) }
        guard !hidden.isEmpty else { return nil }
        return hidden.count == 1
            ? "One hidden file matches. Show hidden files to see it."
            : "\(hidden.count) hidden files match. Show hidden files to see them."
    }

    /// The hint, but only after the wait has gone on long enough to be worth explaining.
    private var slowReadHint: String? {
        waitingLongEnough ? waitingHint : nil
    }

    private func list(_ directory: RemoteDirectory) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Lazy, because a listing can be two thousand rows and a plain stack builds all of
            // them whether or not anyone scrolls that far.
            LazyVStack(spacing: 0) {
                // The row a shell browser would have. Written as `..` rather than as the parent's
                // name because that is what the audience reads: this panel lives in a terminal,
                // and the two dots are what a terminal has always called "up one level".
                if let parent {
                    upRow(parent)
                    if !visible(directory).isEmpty { Controls.divider }
                }
                ForEach(Array(visible(directory).enumerated()), id: \.element.name) { index, entry in
                    if index > 0 { Controls.divider }
                    row(entry)
                }
                if directory.isTruncated {
                    if !visible(directory).isEmpty { Controls.divider }
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

    /// One entry: a glyph, its name, what it is, and the way in.
    ///
    /// The same row as the app's other lists — see ``SSHQuickCommandsEditor/row`` — because it is
    /// the same object: a thing with a name, a line about it, and something on the other side of
    /// the tap.
    private func row(_ entry: RemoteDirectoryEntry) -> some View {
        Button {
            // Opening something is leaving the list, and a keyboard left up over the folder that
            // arrives next is one the user has to put away before they can see it.
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
                    // No font here — the two runs of it are set in two faces inside — and one line
                    // only, because a row whose second line wrapped would be a row of two heights
                    // in a list read by scanning down it.
                    detail(for: entry)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                // Pointing rather than offering to open: a tap on a file shows what is in it, and
                // a tap on a folder goes into it. Both are "in there", so both get the same glyph.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Put path in command line", systemImage: "arrow.up.forward.square") {
                onRevealPath(childPath(entry.name, of: path))
            }
        }
    }

    /// The row out of this folder, drawn as a folder row so the list keeps one shape.
    private func upRow(_ parent: String) -> some View {
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
    private var parent: String? {
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
    private func detail(for entry: RemoteDirectoryEntry) -> Text {
        guard !entry.permissions.isEmpty else {
            let word = entry.isSymlink ? "Symbolic link" : (entry.isDirectory ? "Folder" : "File")
            return Text(word).font(.caption)
        }

        var parts: [String] = []
        if entry.isSymlink {
            parts.append("Symbolic link")
        } else {
            // The empty file is named rather than counted, because Foundation will not: every
            // combination of `byteCount`'s options answers zero bytes with "Zero kB", which is a
            // unit for a thing that has none. This is the one row in a folder where the number is
            // the whole of what there is to say, and wrong is worse here than verbose.
            parts.append(entry.size == 0 ? "Zero bytes" : entry.size.formatted(.byteCount(style: .file)))
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
    private func visible(_ directory: RemoteDirectory) -> [RemoteDirectoryEntry] {
        let listed = showsHidden ? directory.entries : directory.entries.filter { !$0.name.hasPrefix(".") }
        guard isFiltering else { return listed }
        return listed.filter(matches)
    }

    /// Whether a name is one the user is looking for.
    ///
    /// `localizedStandardContains` rather than a plain one, which is the same comparison the two
    /// providers sort by: it is insensitive to case and to accents, and it puts `file 10` where a
    /// Finder would — so what the filter keeps is in the order it was already in.
    private func matches(_ entry: RemoteDirectoryEntry) -> Bool {
        isFiltering ? entry.name.localizedStandardContains(needle) : true
    }

    private func emptyMessage(_ directory: RemoteDirectory) -> String {
        if directory.entries.isEmpty { return "This folder is empty." }
        if isFiltering { return "Nothing in this folder matches “\(needle)”." }
        return "Everything in this folder is hidden."
    }

    // MARK: - Loading, empty and failed

    private func state(
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
    /// ``TerminalPanel``. Shared here by being the same one point of the same white.
    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}

/// A text file on a server, as far as it was read — and, when it can be, edited.
///
/// **Reading and editing are two modes rather than one editable view, and that is not a
/// compromise.** What makes this panel good at reading is that it does not wrap: a config, a script
/// and a log are all read by their columns, so the readout is monospaced, scrolls on both axes, and
/// lets a long line run off the side where it belongs. A text field cannot do that — it wraps, and
/// it has one axis — so an editable readout would be a worse reader in exchange for being a writer.
/// The mode is what lets each half be the best version of itself.
///
/// The size line says when what is on screen is the beginning of a file rather than the whole of
/// one, and that line is load-bearing rather than informative: **a file that was cut short cannot be
/// edited or downloaded**, because both of those would act on 128 KB as though it were the file.
/// See ``SSHModel/saveFile(_:sessionID:)`` for why the guard is enforced there as well as here.
struct FilePreviewPanel: View {
    let preview: RemoteFilePreview
    let failure: String?
    /// Whether a write is in flight, and the last one that went wrong.
    var isSaving: Bool = false
    var saveFailure: String?

    var onRevealPath: (String) -> Void
    var onClose: () -> Void
    /// Writes the text given back to the server. Absent where the file cannot be written — the
    /// Mac's own browser, which has no such door yet.
    var onSave: ((String) -> Void)?

    /// The text being edited, or `nil` while the file is only being read.
    @State private var edited: String?
    /// A copy of the file on this phone, so it can be handed to Files. See ``temporaryCopy()``.
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Prepared when the file arrives rather than when the button is pressed: the share sheet
        // reads the file as it opens, so a URL that does not exist yet is a share sheet that comes
        // up empty. The file is at most the preview cap, so this is not a cost worth deferring.
        .task(id: preview.path) {
            shareURL = preview.isTruncated ? nil : Self.temporaryCopy(of: preview)
        }
    }

    /// Whether this file may be changed at all.
    ///
    /// Three ways to be no, and they are different sentences on screen: the file was cut short at
    /// the read cap, it is not the whole of itself yet, or whoever opened this panel has no way to
    /// write one back.
    private var canEdit: Bool {
        onSave != nil && preview.isComplete && !preview.isTruncated && failure == nil
    }

    /// Whether there is anything on screen to edit — an empty file is still a file.
    private var isEditing: Bool { edited != nil }

    private var hasUnsavedChanges: Bool {
        guard let edited else { return false }
        return edited != preview.text
    }

    private var header: some View {
        HStack(spacing: 11) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the folder")

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isEditing {
                // Words rather than glyphs on this side, unlike the reading side: mid-edit the two
                // choices are the whole question on the screen, and a tick and a cross are two
                // guesses about which does which.
                Button("Cancel") { edited = nil }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)

                Button {
                    if let edited { onSave?(edited) }
                } label: {
                    Text(isSaving ? "Saving…" : "Save")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(hasUnsavedChanges && !isSaving ? ColorPalette.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges || isSaving)
            } else {
                // Absent rather than disabled when the file was cut short: a greyed control invites
                // a tap and explains nothing, and the size line above already says why.
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Download to this phone")
                }

                if canEdit {
                    Button { edited = preview.text } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit this file")
                }

                Button { onRevealPath(preview.path) } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Put path in command line")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { hairline }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEditing {
            editor
        } else if !preview.isComplete {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if preview.data.isEmpty {
            Text("This file is empty.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            text
        }
    }

    /// The file, laid out the way the terminal lays out its output.
    ///
    /// Two scroll views and no wrapping, for the same reason the log has them: a text file read on
    /// a phone is usually a config, a script or a log, and every one of those is read by its
    /// columns. Lines that wrapped would lose the only structure they have.
    private var text: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(preview.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ColorPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }

    /// The file, being changed.
    ///
    /// Autocorrection and capitalisation are off, and neither is a preference: this is a config file
    /// or a script, and a keyboard that capitalises the first word of a line or straightens a quote
    /// has silently changed what the file means before anybody saved it. Smart punctuation is a
    /// system keyboard setting that SwiftUI gives no way to reach from here — worth knowing, because
    /// it is the one that still gets through.
    private var editor: some View {
        VStack(spacing: 0) {
            if let saveFailure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(saveFailure)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ColorPalette.caution)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorPalette.caution.opacity(0.12))
            }

            TextEditor(text: Binding(
                get: { edited ?? preview.text },
                set: { edited = $0 }
            ))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(ColorPalette.ink)
            .scrollContentBackground(.hidden)
            .background(ColorPalette.backdrop)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            .padding(.horizontal, 4)
        }
    }

    private var name: String {
        preview.path.split(separator: "/").last.map(String.init) ?? preview.path
    }

    /// A copy of the file on this phone, so the system's share sheet can take it somewhere.
    ///
    /// **This is what downloading means on iOS**, and it is worth being explicit about because it is
    /// not what it means anywhere else: an app has no downloads folder it may write into, so the
    /// file goes to a temporary location and the sheet decides where it lands — Files, another app,
    /// an email. Named after the file it came from, because the name is the only thing about it that
    /// survives the journey.
    ///
    /// `nil` when the bytes are not the whole file, which the caller checks as well: handing
    /// somebody the first 128 KB of their own file under its real name is worse than not offering it.
    private static func temporaryCopy(of preview: RemoteFilePreview) -> URL? {
        let name = preview.path.split(separator: "/").last.map(String.init) ?? "file"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try preview.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// What was read, and how much of the file that was.
    private var detail: String {
        let read = preview.data.count.formatted(.byteCount(style: .file))
        guard preview.isTruncated else { return read }
        return "Showing the first \(read) of \(preview.totalBytes.formatted(.byteCount(style: .file)))"
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}

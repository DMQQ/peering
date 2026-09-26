import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
import os

extension FileBrowserPanel {
    // MARK: - The three dialogs

    var createTitle: String {
        pendingCreate == .folder ? "New Folder" : "New File"
    }

    /// The confirmation's title and button, which sharpen when the folder is not empty.
    ///
    /// **The emptiness check reads the raw listing rather than the rows on screen**, and that is
    /// the safe direction rather than an oversight: a folder holding only hidden files draws as an
    /// empty folder and is not one, so checking `entries` warns about exactly the case a visible-
    /// rows check would get wrong. The listing is already in hand, so this costs nothing.
    var deleteIsRecursive: Bool {
        guard let directory, pendingDelete?.isDirectory == true else { return false }
        return !(directory.entries.isEmpty && !directory.isTruncated)
    }

    var deleteTitle: String {
        guard let entry = pendingDelete else { return "Delete" }
        return deleteIsRecursive
            ? "Delete “\(entry.name)” and everything in it?"
            : "Delete “\(entry.name)”?"
    }

    var deleteButtonTitle: String { deleteIsRecursive ? "Delete All" : "Delete" }

    /// What will go, and what becomes of it. Two sentences because they answer two questions: the
    /// first is the panel's, since only the panel can see whether the row is a folder; the second
    /// is the caller's, since only the caller knows which machine is behind it.
    var deleteMessage: String {
        let scope = pendingDelete?.isDirectory == true
            ? "The folder and everything inside it will go."
            : "The file will go."
        return scope + " " + deleteHint
    }

    // MARK: - Header

    /// Where this folder is, and what is being looked for in it.
    ///
    /// One band rather than two: they are the same two answers about the same list, and a second
    /// strip of grey above the rows is a screen with less room for the rows.
    var header: some View {
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
    /// The filter, and the controls that change the folder rather than the view of it.
    ///
    /// Side by side rather than inside the capsule with the filter: the field is a place to type
    /// and a button in it is a glyph competing with the clear cross for the same corner, where
    /// these are a different kind of thing altogether — they are the only controls on the panel
    /// that change the machine rather than what is being looked at.
    ///
    /// Three of them now, and the create one is a menu rather than two buttons. A third circle in
    /// this row would leave the filter field — the thing people actually use — squeezed between
    /// glyphs, and "new file or new folder" is one question with two answers, which is what a menu
    /// is for.
    @ViewBuilder
    var searchField: some View {
        HStack(spacing: 8) {
            filterField

            if onCreate != nil {
                Menu {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        beginCreate(.folder)
                    }
                    Button("New File", systemImage: "doc.badge.plus") {
                        beginCreate(.file)
                    }
                } label: {
                    chrome("plus")
                }
                // Disabled rather than hidden while a change is in the air, because the operation
                // is quick and a control that vanishes under the finger reads as a bug. It is the
                // machine's answer that decides when this comes back.
                .disabled(isChanging)
                .accessibilityLabel("New file or folder")
            }

            if onUpload != nil {
                // **The button rather than the row, and it keeps the button's shape.** Sending a
                // file to a Mac is the single most consistent paywall in remote desktop, and a free
                // user who never sees the control never finds out the app can do it. What they see
                // instead is the same arrow in the same circle, dimmed, with the plan's name on its
                // corner: an arrow is what says which of these circular controls sends a file up, and
                // a badge in its place would say only that something here costs money. Tapping it
                // opens the plans rather than doing nothing, because a control that answers a
                // press with silence reads as broken.
                PlanLocked(
                    capability: .fileTransfer,
                    // Named for what it will actually take. "Upload a file" was right when that was
                    // all it did, and a folder the user has is a folder they may well want here: a
                    // control that says file and accepts a folder under-promises, and the one that
                    // says folder and refuses is worse. Both browsers send a file either way, so
                    // the wider word costs nothing on the one that cannot take more.
                    title: "Send a file or a folder here",
                    diameter: 32
                ) {
                    Button { showsImporter = true } label: {
                        chrome("arrow.up.to.line")
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.9))
                    .disabled(isChanging)
                    .accessibilityLabel("Send a file or a folder here")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// One of the circular controls at the trailing end of the filter row.
    ///
    /// Written once because there are two of them now and they are meant to be indistinguishable
    /// from each other: same 32 points, same 7% circle, same 13-point semibold glyph on the ink.
    /// Two spellings of this would be two chances for one of them to drift a point to the left.
    func chrome(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ColorPalette.ink)
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.07), in: Circle())
            .contentShape(Circle())
    }

    /// Opens the name dialog with a name nothing in this folder is using.
    ///
    /// The default is the Finder's, and the collision check runs against **the raw listing rather
    /// than the visible rows** — a folder holding a hidden `New Folder` draws as though the name
    /// were free, and the machine would then refuse the name the app had just chosen. Being told
    /// that a name you did not type is taken is the most confusing answer this panel could give.
    func beginCreate(_ kind: RemoteEntryKind) {
        let base = kind == .folder ? "New Folder" : "New File"
        let suffix = kind == .folder ? "" : ".txt"
        nameDraft = RemoteFileName.available(
            base: base,
            extension: suffix,
            among: directory?.entries.map(\.name) ?? []
        )
        pendingCreate = kind
    }

    var filterField: some View {
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
    var breadcrumbs: some View {
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
    var segments: [(title: String, path: String)] {
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
}

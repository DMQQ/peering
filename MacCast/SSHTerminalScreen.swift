import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI

/// A shell on a server.
///
/// Built alongside ``TerminalPanel`` rather than inside it. That panel is the Mac's terminals, and
/// every part of it that could have been shared already is — the sanitizer, the command field, the
/// waiting animation. What is left is genuinely different: these tabs are servers rather than
/// shells on one Mac, a session ends when the tab is closed rather than by asking the Mac to, and
/// there is no command history because a history is a thing the Mac remembers.
struct SSHTerminalScreen: View {
    let model: SSHModel
    let terminal: SSHTerminal

    /// The saved commands. Owned by the app because the Mac's terminals show the same list.
    @Environment(QuickCommands.self) private var quickCommands

    /// Whether the tips for a shell on a server have been seen, and whether the terminal's have.
    ///
    /// **Two tours on one screen, and they are not the same tour twice.** This screen is two
    /// things at once: a connection, which is the strip of shells and the output that arrives
    /// through it, and a terminal, which is the keys and the line that types. A person meets them
    /// in that order, the connection arriving before there is anything to type at, so they are two
    /// runs of the same mechanism and the screen hands them over in that order. See ``dueTours``.
    @AppStorage(PreferenceKeys.hasSeenTourShell) private var hasSeenTourShell = false
    @AppStorage(PreferenceKeys.hasSeenTourTerminal) private var hasSeenTourTerminal = false

    @State private var command = ""
    /// A plain flag rather than `@FocusState`, for the reason spelled out at length in
    /// ``TerminalPanel``: the field is a `UITextField` owning its own responder status, and
    /// SwiftUI clears a `@FocusState` that no `.focused()` modifier ever claimed.
    @State private var inputFocused = false
    /// The last size sent, so a layout pass that did not actually change the number of cells does
    /// not send a window-change request the server has to answer for nothing.
    @State private var lastColumns = 0
    @State private var lastRows = 0
    /// Whether new output should pull the view down, or leave it where the user scrolled to.
    @State private var stickToBottom = true
    @State private var isEditingQuickCommands = false

    /// Whether the screen is showing the server's folders instead of the shell.
    ///
    /// The shell is not put away while this is on: it is still connected, still running and still
    /// receiving output, and the screen is only showing something else. The one thing the browser
    /// does to the shell is change its directory, and only when a folder is opened.
    @State private var isBrowsing = false

    /// Whether the port forwards are being shown.
    ///
    /// Held here rather than on the model, unlike the password sheet's host, because this one is
    /// about the connection this screen is showing rather than about the server: the question
    /// "which shell's forwards" has one answer while this screen is up, and it is this one.
    @State private var isShowingForwards = false

    /// The port button's glyph, which carries the state without the sheet being opened.
    ///
    /// A running forward has to look different from a stopped one from here, because the whole of
    /// what the user needs to know at a glance is whether traffic is going through a tunnel: the
    /// sheet is where the detail is, and a user who has to open a sheet to find out whether their
    /// port is open is a user who will not bother.
    private var portsSymbol: String {
        if model.hasBrokenForward(on: terminal.host) { return "exclamationmark.triangle" }
        return model.hasRunningForward(on: terminal.host) ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted"
    }

    private var portsTint: Color {
        if model.hasBrokenForward(on: terminal.host) { return ColorPalette.caution }
        return model.hasRunningForward(on: terminal.host) ? ColorPalette.accent : .secondary
    }
    /// Whether dotfiles are listed. Filtered here rather than by the server, so that both of this
    /// app's browsers answer the question the same way.
    @State private var showsHiddenFiles = false

    var body: some View {
        VStack(spacing: 0) {
            // Drawn for one shell as well as for several, which it was not.
            //
            // It was hidden when there was only one, on the good argument that a single tab is
            // not a choice — and that is still true, but the row is also the one place the end
            // question can be asked from without the card running off the edge of the screen. It
            // paid for itself further with one shell than it was costing: the status dot and the
            // cross on it are about that shell, and the row is what ``TerminalPanel`` draws for
            // the Mac's terminals whatever their number.
            tabStrip
                .tourAnchor(.shellTabs)
                .terminalEndPrompt(
                    name: model.pendingClose?.title ?? "",
                    detail: "The shell on the server stops, along with anything running in it. Your other shells are left alone.",
                    isPresented: Binding(
                        get: { model.pendingClose != nil },
                        set: { if !$0 { model.pendingClose = nil } }
                    ),
                    onEnd: {
                        guard let terminal = model.pendingClose else { return }
                        model.close(terminal)
                        model.pendingClose = nil
                    }
                )
            if isBrowsing {
                browsing
            } else {
                output
                    .tourAnchor(.shellOutput)
                // The saved commands and the keys in one row, shared with the Mac's terminals —
                // see ``TerminalDeck``, which is where the two strips this screen used to stack
                // went and why.
                TerminalDeck(
                    commands: quickCommands.all,
                    run: { model.run($0, on: terminal) },
                    remove: { quickCommands.delete($0) },
                    // The same split as the Mac's terminals: the saved commands stay and can be
                    // run, and what Pro adds is making one. Both callers hand the deck the same
                    // button for the same reason, so the two strips cannot come to different
                    // conclusions about the same user. The gate is the deck's own.
                    edit: { isEditingQuickCommands = true },
                    send: { model.send(Data($0.utf8), to: terminal) },
                    isEnabled: canType
                )
                .tourAnchor(.terminalDeck)
                input
                    .tourAnchor(.terminalInput)
            }
        }
        // On the screen's own stack, inside the navigation stack the Servers tab wraps it in: the
        // steps are measured off the strip, the log and the row below, and a preference does not
        // travel out through a navigation container.
        .firstRunTours(dueTours) { $0.markSeen() }
        .sheet(isPresented: $isEditingQuickCommands) {
            SSHQuickCommandsEditor(commands: quickCommands)
        }
        .background(Color.black)
        // The whole screen, and no tab bar under it.
        //
        // This screen is the Servers tab's root rather than something pushed onto it — see
        // ``SSHTab`` — so without this the five tabs of the app sit along the bottom edge of a
        // running shell, a few points under the row that types into it. That is chrome from a
        // different screen, in the one place a terminal wants every point it can get: a shell is
        // read from the bottom up, and the line the cursor is on was the line nearest the tabs.
        //
        // Hiding it is the smallest correct answer, and it is worth saying why it is not a
        // separate stack as well. A shell is not a place the user browses to and away from; it is
        // a thing they are *in* while they use it, and the tab bar is a way out of it that leads
        // somewhere with nothing to do with it. Going back to the list is one tap, on the chevron,
        // and it is the same tap that gets the tabs back.
        .toolbar(.hidden, for: .tabBar)
        // Inline, and *not* a two-line `principal` item. A principal view that is taller than one
        // line grows the whole navigation bar with it, which pushed the tab strip down and left a
        // band of empty chrome above the terminal. The `user@host` it used to carry is in the
        // Servers list, where a machine is being chosen and the detail is what tells two apart.
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Leaving, not hanging up. The shell keeps running and `SSHTab` offers it back
                // under "Open" — which is why this is a chevron and the other end of the bar is
                // red: two actions that both leave this screen must not look like one action.
                Button("Servers", systemImage: "chevron.left") { model.leaveTerminal() }
            }
            // The switch between the shell and the server's folders is not here. It is pinned to
            // the end of the tab strip — see ``TerminalModeButton`` for why the leading end of a
            // navigation bar turned out to be the wrong place for it.
            //
            // A second shell on the same machine, from inside the first — which is where anyone
            // would look for it. It was reachable only by leaving this screen, long-pressing a
            // server in the list and picking "New shell", which is not a place anybody goes
            // looking for a tab. `TerminalPanel` has put a `+` in this exact spot for the Mac's
            // own terminals all along.
            ToolbarItem(placement: .topBarTrailing) {
                // The same button in the same place on every plan. A second shell from inside the
                // first is the one anyone would look for, so it is the last place to hide the fact
                // that several are possible: on a plan that runs one shell at a time the plus is
                // still a plus, dimmed, with the plan's name on its corner, and the tap opens the
                // plans rather than a shell.
                PlanLocked(capability: .shellTabs, title: "New shell", diameter: 20) {
                    Button("New shell", systemImage: "plus") {
                        model.openAnotherShell(on: terminal)
                    }
                    .accessibilityHint("Opens another shell on \(terminal.host.displayName)")
                }
            }
            // Only on a server that carries forwards, because on any other server it would be a
            // button opening a sheet whose only content is a sentence saying there is nothing here.
            if !terminal.host.forwards.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ports", systemImage: portsSymbol) {
                        isShowingForwards = true
                    }
                    .tint(portsTint)
                    .accessibilityHint("Shows the port forwards this shell is carrying")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // The question this raises is asked from the tab strip at the top of the panel,
                // not from here — see ``terminalEndPrompt(_:name:detail:isPresented:onEnd:)``
                // for why a popover cannot be trusted to stay on screen when it is anchored to
                // a button in this corner of it. With one shell open this is the only thing on
                // screen that ends anything, so raising the question is the whole of its job.
                Button("End", systemImage: "xmark.circle") { model.requestClose(terminal) }
                    .tint(ColorPalette.danger)
                    .accessibilityHint("Ends the shell on the server")
            }
        }
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { inputFocused = true }
        .sheet(isPresented: $isShowingForwards) {
            SSHForwardsSheet(host: terminal.host, model: model)
        }
        // Switching shells while the browser is open looks at the same folder in the other shell.
        // The folder is where the user is looking, not something a shell owns, and a browser left
        // pointing at a folder the new shell has never been asked about would spin at nothing.
        //
        // Asked for through the *new* selection's own path rather than through ``browsingPath``,
        // which describes the shell this screen was built for a moment ago — the two are the same
        // only once the body has been rebuilt, and which of them the closure sees is not something
        // worth relying on.
        .onChange(of: model.selectedTerminalID) { _, id in
            guard isBrowsing, let id, model.openShells.contains(where: { $0.id == id }) else { return }
            model.listDirectory(model.browsingPath(for: id), sessionID: id)
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var output: some View {
        if terminal.output.isEmpty, case .connecting = terminal.phase {
            TerminalStarting()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            log
        }
    }

    /// `TerminalPanel`'s log, over this shell's bytes.
    ///
    /// Wrapping is off and horizontal scrolling is the inner view, so columns from a `ls` or a
    /// `top` line up — the same trade that panel makes, for the same reason.
    private var log: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(coloured)
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                // What the vertical scroll follows. A one-point view at the end of the text.
                Color.clear.frame(height: 1).id(Self.endMarker)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = true }
            // Whether the picture follows new output or stays where the user put it.
            //
            // Deliberately *not* `.defaultScrollAnchor(.bottom)`, which is what this had first and
            // what made the view impossible to read while a full-screen program was running. That
            // modifier pins the anchor as content grows, so every redraw `htop` sends dragged the
            // view back to the bottom — and the `onChange` below did it a second time on top. The
            // result was a scroll that snapped away the moment the drag ended, which is not a
            // scroll at all.
            //
            // A terminal sticks to the bottom until the user scrolls up, and then it leaves them
            // alone until they come back down. That is the whole rule, and it needs the position
            // measured rather than assumed.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let fromBottom = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return fromBottom <= Self.bottomSlack
            } action: { _, atBottom in
                stickToBottom = atBottom
            }
            .onChange(of: terminal.output.count) { _, _ in
                guard stickToBottom else { return }
                reader.scrollTo(Self.endMarker, anchor: .bottom)
            }
            .task {
                // The opening position, which `defaultScrollAnchor` used to give for free: a shell
                // that has been printing since before the view existed opens at the end of its
                // output rather than at the top of a wall of text.
                reader.scrollTo(Self.endMarker, anchor: .bottom)
            }
            .background {
                // The server is told how big the terminal is, or every full-screen program on the
                // far end draws at the 80×24 a PTY defaults to — `vim` and `top` would lay out for
                // a window that does not exist and wrap in the wrong places. Measured on the log
                // rather than on the screen, because the key strip and the input row are not part
                // of what the shell gets to draw on.
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        apply(size)
                    }
                }
            }
        }
    }

    private static let endMarker = "ssh-terminal-end"

    /// The log's type size, in one place because it is used twice: the base font for the whole
    /// log, and the bold runs inside it. Two spellings of it is a bold word that is a point
    /// bigger than the line it sits on.
    /// The log's type size, the same preference the Mac's own terminal reads. See
    /// ``TerminalMetrics/TextSize``.
    @AppStorage(PreferenceKeys.terminalTextSize) private var textSize = TerminalMetrics.TextSize.regular.rawValue

    private var fontSize: CGFloat { TerminalMetrics.TextSize.named(textSize).points }

    /// How close to the bottom still counts as "at the bottom".
    ///
    /// Not zero, because a scroll view rarely lands exactly on the edge and a terminal that stops
    /// following output because it is 2 points short of the end is worse than one that follows
    /// slightly too eagerly.
    private static let bottomSlack: CGFloat = 24

    /// Character cells, from the measured size of the log. See ``TerminalMetrics``.
    private func apply(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let columns = TerminalMetrics.columns(forWidth: size.width, fontSize: fontSize)
        // Rows only ever grow: the keyboard and the key deck shorten the log, and neither is a
        // change to the server's screen. See ``TerminalPanel/applySize(_:to:)``, which is the same
        // rule for the Mac's own shells.
        let rows = max(lastRows, TerminalMetrics.rows(forHeight: size.height, fontSize: fontSize))
        guard columns != lastColumns || rows != lastRows else { return }
        lastColumns = columns
        lastRows = rows
        model.resize(columns: columns, rows: rows, for: terminal)
    }

    private var coloured: AttributedString {
        guard !terminal.output.isEmpty else {
            return AttributedString("Nothing was printed.")
        }

        // One renderer, shared with the Mac's own terminal — see ``TerminalPalette/attributed(_:fontSize:)``.
        var rendered = TerminalPalette.attributed(terminal.styled, fontSize: fontSize)

        // Why it ended, if it ended badly, in the one red the app uses for a failure — the same
        // red as the line above it that explains the failure in the server's own words.
        if case .ended(let reason) = terminal.phase, let reason {
            var note = AttributedString("\n" + reason + "\n")
            note.foregroundColor = ColorPalette.danger
            rendered.append(note)
        }

        return rendered
    }

    // MARK: - Tabs

    /// The shells, and the switch to the server's folders pinned to the end of them.
    ///
    /// The chip is outside the scroller rather than a last item in it, which is the whole of why
    /// it is findable: among the tabs it would slide away as shells are opened, and the one control
    /// on this row that is not a shell is the one that must not be somewhere else every time the
    /// row changes length. See ``TerminalModeButton`` for why it is on this row at all.
    private var tabStrip: some View {
        // The selection is the shell this screen *is*, not the model's idea of the current one.
        // Each shell gets a screen of its own, so the strip is only ever drawn by the screen being
        // looked at, and the one it should mark is the one it belongs to.
        TabStrip(items: model.openShells, selection: terminal.id) { open, isSelected in
            chip(open, isSelected: isSelected)
        } accessory: {
            TerminalModeButton(isBrowsing: isBrowsing) { toggleBrowsing() }
                .padding(.top, 11)
                .padding(.trailing, 8)
        }
    }

    /// What this screen owes, connection first.
    ///
    /// The order is the order a person meets them: the strip and what it has printed are what
    /// arriving on this screen is, and the keys and the command line are what using it is. The
    /// second tour is not started until the first has been answered, because they are shown by one
    /// mechanism (``firstRunTours(_:onDismiss:)``) which takes them in this order and runs them one
    /// at a time.
    ///
    /// Deliberately *not* gated on the shell being live. A shell that failed still has a strip, a
    /// switch and a terminal, and those are what the tips are about; the one thing that would be
    /// absurd is a tour about typing at a shell that has ended, and nothing in these steps says
    /// anything untrue of one.
    private var dueTours: [Tour] {
        var due: [Tour] = []
        if !hasSeenTourShell { due.append(.shell) }
        if !hasSeenTourTerminal { due.append(.terminal) }
        return due
    }

    private func chip(_ open: SSHTerminal, isSelected: Bool) -> some View {
        TabChip(
            isSelected: isSelected,
            onSelect: { model.selectedTerminalID = open.id },
            onClose: { model.requestClose(open) },
            // The close is on the tab. Without it the only way out of a shell was the toolbar —
            // and with several shells to the *same* host open, ending one just showed another
            // identical one, so the button read as broken.
            closeLabel: "End \(open.title)"
        ) {
            Circle()
                .fill(statusTint(open))
                .frame(width: 6, height: 6)
        } name: {
            TabName(
                text: open.title,
                isSelected: isSelected,
                colour: isSelected ? ColorPalette.ink : Color.secondary
            )
        }
    }

    private func statusTint(_ open: SSHTerminal) -> Color {
        switch open.phase {
        case .connecting: return ColorPalette.caution
        case .live: return .green
        case .ended: return ColorPalette.danger
        }
    }

    /// Whether the shell will accept anything at all. A session that has ended — failed or hung
    /// up — takes no keys and no lines, and leaving the controls live would send input into a
    /// socket that is already gone.
    private var canType: Bool {
        if case .ended = terminal.phase { return false }
        return true
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    // MARK: - Browsing

    /// The folder being browsed, as far as this screen knows it.
    private var browsingPath: String? {
        model.browsingPath(for: terminal.id)
    }

    /// Where something would be made, renamed or deleted. Only meaningful when ``canMake``.
    ///
    /// The empty string is unreachable rather than a fallback: ``canMake`` is false whenever this
    /// is `nil`, and every closure that reads it is `nil` at the same time.
    private var folder: String { browsingPath ?? "" }

    /// Whether this browser can change anything on the server.
    ///
    /// Both halves are needed. The shell has to be live, because every change is a request through
    /// it; and the folder has to have resolved, because a change names a path and the path is the
    /// one thing this screen does not have until the server has said where the browser is.
    private var canMake: Bool { canType && browsingPath != nil }

    /// The browser, or the file it is showing, in the terminal's place.
    ///
    /// **In place of, never over**, which is the Mac panel's rule and a stronger one here: the log
    /// carries a tap that sends focus to the keyboard, so anything laid on top of it would swallow
    /// that tap and give nothing back. Swapping them also leaves the PTY size alone. The
    /// `GeometryReader` that reports it lives on the log, and with the log out of the hierarchy
    /// nothing is measured — so ``apply(_:)``'s change guard makes the return trip a no-op, and
    /// nothing on the far end reflows for a screen the shell never stopped drawing for.
    private var browsing: some View {
        VStack(spacing: 0) {
            if let preview = model.filePreview, preview.terminalID == terminal.id {
                FilePreviewPanel(
                    preview: preview,
                    failure: model.browseFailure(preview.path, sessionID: terminal.id),
                    isSaving: model.isSavingFile,
                    saveFailure: model.saveFailure,
                    onRevealPath: { reveal($0) },
                    onClose: { model.closePreview() },
                    onSave: { model.saveFile($0, sessionID: terminal.id) }
                    // Both directions of the transfer are one capability and the panel's own gate,
                    // so the two browsers answer this the same way and neither can be the one that
                    // forgot.
                )
            } else {
                FileBrowserPanel(
                    path: browsingPath,
                    directory: model.directory(browsingPath, sessionID: terminal.id),
                    isLoading: model.isLoadingDirectory(browsingPath, sessionID: terminal.id),
                    // A shell that has ended is not a folder that failed. The session refuses
                    // every browse request for one, so the panel says that itself rather than
                    // asking and leaving a spinner on a server that has already stopped answering.
                    // An upload that failed is shown in the folder's own failure slot rather than
                    // one of its own: it is a fact about this folder, it is cleared by the next
                    // attempt, and a second place for a sentence to appear in a panel this short
                    // would be a second layout to keep right.
                    failure: canType
                        ? (model.uploadFailure
                            ?? model.browseFailure(browsingPath, sessionID: terminal.id))
                        : "This shell has ended. Open a new shell to browse the server's files.",
                    showsHidden: showsHiddenFiles,
                    onOpen: { open($0) },
                    onNavigate: { navigate(to: $0) },
                    onRevealPath: { reveal($0) },
                    onReload: {
                        guard canType else { return }
                        model.listDirectory(browsingPath, sessionID: terminal.id)
                    },
                    // Absent while the shell has ended, for the same reason the folder cannot be
                    // listed then: there is no connection left to send anything down, and an
                    // upload button that opens a picker and then fails is worse than no button.
                    onUpload: canType
                        ? { model.uploadFile($0, sessionID: terminal.id) }
                        : nil,
                    // Two different reasons for a transfer not to be on offer, and the panel draws
                    // them differently: an account without file transfer gets the button dimmed
                    // with the plan's name on its corner, which is the panel's own gate now, and
                    // the `nil` above is about a shell that has ended.
                    // And absent for the same reason: a run types a command into the shell, so a
                    // shell that has ended is one with nothing to type into.
                    onRun: canType ? { run($0) } : nil,
                    // An SFTP server has no Trash, so this is the one place the two browsers differ
                    // in what the same word means. Said plainly, because a user who has learned
                    // that Delete on their Mac is recoverable would otherwise bring that
                    // expectation to a server where it is not.
                    deleteHint: "This cannot be undone on the server.",
                    // The three changes, absent together and for two reasons rather than one. A
                    // session that has ended answers none of them, and a folder that has not
                    // resolved yet is not a place to make anything in — `.` would be wherever the
                    // server happened to start the shell rather than the folder on screen, which is
                    // the one thing this browser never guesses at. The panel draws no rows until
                    // the path arrives, so this is a window nobody can act in.
                    onCreate: canMake
                        ? { model.createEntry($0, kind: $1, in: folder, sessionID: terminal.id) }
                        : nil,
                    onRename: canMake
                        ? { model.renameEntry($0, to: $1, in: folder, sessionID: terminal.id) }
                        : nil,
                    onDelete: canMake
                        ? { model.deleteEntry($0, in: folder, sessionID: terminal.id) }
                        : nil,
                    isChanging: model.isChangingFile,
                    changeFailure: model.changeFailure
                )
            }
            browseControls
        }
    }

    /// The row under the browser, which is ``FileBrowseBar`` — the same row the Mac panel draws
    /// under its own, because it is the same set of controls acting on the same kind of list.
    ///
    /// The interrupt key is on it for a reason worth keeping written down: browsing does not stop
    /// a runaway command, and the key strip is exactly what this mode takes away — so the keys
    /// that survive here are the ones a shell is still being driven with while its output is out
    /// of sight.
    private var browseControls: some View {
        FileBrowseBar(
            isEnabled: canType,
            showsHidden: showsHiddenFiles,
            onInterrupt: { model.send(Data("\u{03}".utf8), to: terminal) },
            onEscape: { model.send(Data("\u{1B}".utf8), to: terminal) },
            onTab: { model.send(Data("\t".utf8), to: terminal) },
            onReload: { model.listDirectory(browsingPath, sessionID: terminal.id) },
            onToggleHidden: { showsHiddenFiles.toggle() }
        )
    }

    /// The switch between the shell and the server's files, as one action rather than two.
    ///
    /// It sends nothing. Browsing is a way of looking at a server's folders and, when a folder is
    /// opened, of asking the shell to change directory — there is no state here the shell is told
    /// about. What it does either way is draw the difference: the button that calls this is in the
    /// header on both screens — see ``TerminalModeButton``.
    private func toggleBrowsing() {
        withAnimation(Motion.tap) { isBrowsing.toggle() }
        if isBrowsing {
            // Asked for on every entry rather than only the first: a folder is the one screen
            // where what is on it can have changed since it was last looked at. Not asked for
            // at all from a shell that has ended, where the request would be refused and the
            // refusal would land on a browser nobody can then reload.
            if canType { model.listDirectory(browsingPath, sessionID: terminal.id) }
        } else {
            model.closePreview()
        }
    }

    /// A row was tapped: folders are entered, files are read.
    private func open(_ entry: RemoteDirectoryEntry) {
        let path = childPath(entry.name, of: browsingPath)
        if entry.isDirectory {
            navigate(to: path)
        } else {
            model.previewFile(path, sessionID: terminal.id)
        }
    }

    /// Runs an executable file, in the shell this session already has.
    ///
    /// **In the current shell rather than a new one, and that is a limit rather than a choice.**
    /// An SSH session here is one connection with one shell on it — the Mac's browser can open a
    /// tab because the Mac host can open another login shell, and there is no second one to open
    /// on the far end of this. So the command goes where a `cd` already goes, through the same
    /// door ``navigate(to:)`` uses, and the shell's own history is what holds the receipt.
    ///
    /// The confirmation has already happened: the panel holds it, so neither browser can be the
    /// one that forgot it.
    private func run(_ entry: RemoteDirectoryEntry) {
        let path = childPath(entry.name, of: browsingPath)
        model.send(Data((ShellPath.runCommand(for: path) + "\r").utf8), to: terminal)
        withAnimation(Motion.tap) { isBrowsing = false }
    }

    /// Goes into a folder: the browser shows it, and the shell changes directory to it.
    ///
    /// The `cd` goes in as bytes rather than through the command field, and the reason the Mac
    /// panel gives for the same choice is only half of it here. There is no history and no
    /// retitling on this screen to keep a `cd` out of — but the field is where a *person* types,
    /// and the browser is the screen moving itself. Putting the line in the field and pressing
    /// Return would be two steps pretending to be one, and would leave the last folder visited
    /// sitting in a box waiting to be sent again.
    ///
    /// `cd --` because a path is data: the `--` is what stops a folder called `-P` from being
    /// read as an option, and the quoting is what stops one called `; rm -rf ~` from being read
    /// as a command.
    private func navigate(to path: String) {
        model.setBrowsingPath(path, for: terminal.id)
        model.listDirectory(path, sessionID: terminal.id)
        model.send(Data("cd -- \(ShellPath.quoted(path))\r".utf8), to: terminal)
    }

    /// Puts a path in the command line, which is what a path is usually wanted for.
    ///
    /// Back to the terminal as well as into the field: the field is not on screen while the
    /// browser is, and a path put somewhere nobody can see it is a tap that did nothing. Quoted,
    /// because a path is data and a shell is a shell — what goes in the field is the form that
    /// runs when Return is pressed, which is the same reason the SSH browser quotes the `cd` above.
    private func reveal(_ path: String) {
        withAnimation(Motion.tap) { isBrowsing = false }
        model.closePreview()
        command = ShellPath.quoted(path)
        inputFocused = true
    }

    // MARK: - Input

    private var input: some View {
        HStack(spacing: 8) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide keyboard")

            TerminalCommandField(
                text: $command,
                isFocused: $inputFocused,
                placeholder: "Send a command",
                isEnabled: canType,
                onSubmit: submit
            )
            // A `UITextField` has no intrinsic height, so the frame is here rather than inside the
            // representable, and it is the representable's own number.
            .frame(height: TerminalCommandField.height)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    // Dimmed ink rather than a grey, because the app's palette has no greys —
                    // everything that is not the accent is a brightness of white.
                    .foregroundStyle(command.isEmpty ? ColorPalette.ink.opacity(0.28) : ColorPalette.accent)
            }
            .disabled(command.isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay(alignment: .top) { hairline }
    }

    private func submit() {
        guard canType, !command.isEmpty else { return }
        // The same rule as the Mac's terminals: a program that draws a full screen wants the size
        // that fits one on a phone. See ``TerminalProgram``.
        if TerminalProgram.prefersSmallText(command) {
            textSize = TerminalMetrics.TextSize.tiny.rawValue
        }
        // A newline, which is what a shell's line editor is waiting for. Sent as its own write
        // rather than appended to the text, because the text is what the user typed and the
        // Return is the decision to run it.
        model.send(Data(command.utf8), to: terminal)
        model.send(Data("\r".utf8), to: terminal)
        command = ""
        // Kept up: the keyboard closing after every command is what makes a terminal on a phone
        // unusable — each command would cost a tap to get it back.
        inputFocused = true
    }
}

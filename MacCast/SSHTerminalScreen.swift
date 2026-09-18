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
                // The saved commands and the keys in one row, shared with the Mac's terminals —
                // see ``TerminalDeck``, which is where the two strips this screen used to stack
                // went and why.
                TerminalDeck(
                    commands: quickCommands.all,
                    run: { model.run($0, on: terminal) },
                    remove: { quickCommands.delete($0) },
                    edit: { isEditingQuickCommands = true },
                    send: { model.send(Data($0.utf8), to: terminal) },
                    isEnabled: canType
                )
                input
            }
        }
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
                Button("New shell", systemImage: "plus") {
                    model.openAnotherShell(on: terminal)
                }
                .accessibilityHint("Opens another shell on \(terminal.host.displayName)")
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
                        .font(.system(size: Self.fontSize, design: .monospaced))
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
    private static let fontSize: CGFloat = 12

    /// How close to the bottom still counts as "at the bottom".
    ///
    /// Not zero, because a scroll view rarely lands exactly on the edge and a terminal that stops
    /// following output because it is 2 points short of the end is worse than one that follows
    /// slightly too eagerly.
    private static let bottomSlack: CGFloat = 24

    /// Character cells, from the measured size of the log.
    ///
    /// The divisor is the advance width of the 12-point monospaced face the log is set in, and the
    /// row height its line spacing. Both are approximations, and deliberately so: being one column
    /// out is invisible in a shell prompt, and the alternative is asking CoreText for metrics on
    /// every layout pass to be exact about something nobody can see.
    private func apply(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let columns = max(20, Int(size.width / 7.2))
        let rows = max(6, Int(size.height / 14.4))
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
        var rendered = TerminalPalette.attributed(terminal.styled, fontSize: Self.fontSize)

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
        HStack(spacing: 0) {
            tabs

            TerminalModeButton(isBrowsing: isBrowsing) { toggleBrowsing() }
                .padding(.trailing, 10)
        }
        // The seam, drawn behind the whole row: under the chip as well, which is what keeps the
        // chip sitting on the strip rather than beside it.
        .background(alignment: .bottom) { hairline }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.openShells) { open in
                    let isSelected = open.id == terminal.id
                    // Two buttons side by side rather than one wrapping the other, because a tap
                    // on the close had to not also mean "switch to this tab". Without the close,
                    // the only way out of a shell was the toolbar — and with several shells to the
                    // *same* host open, ending one just showed another identical one, so the
                    // button read as broken.
                    HStack(spacing: 2) {
                        Button {
                            model.selectedTerminalID = open.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusTint(open))
                                    .frame(width: 6, height: 6)
                                Text(open.title)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? ColorPalette.ink : .secondary)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 4)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.requestClose(open)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("End \(open.title)")
                    }
                    .background(isSelected ? Color.white.opacity(0.08) : .clear)
                }
            }
            .padding(.horizontal, 6)
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
                    onRevealPath: { reveal($0) },
                    onClose: { model.closePreview() }
                )
            } else {
                FileBrowserPanel(
                    path: browsingPath,
                    directory: model.directory(browsingPath, sessionID: terminal.id),
                    isLoading: model.isLoadingDirectory(browsingPath, sessionID: terminal.id),
                    // A shell that has ended is not a folder that failed. The session refuses
                    // every browse request for one, so the panel says that itself rather than
                    // asking and leaving a spinner on a server that has already stopped answering.
                    failure: canType
                        ? model.browseFailure(browsingPath, sessionID: terminal.id)
                        : "This shell has ended. Open a new shell to browse the server's files.",
                    showsHidden: showsHiddenFiles,
                    onOpen: { open($0) },
                    onNavigate: { navigate(to: $0) },
                    onRevealPath: { reveal($0) },
                    onReload: {
                        guard canType else { return }
                        model.listDirectory(browsingPath, sessionID: terminal.id)
                    }
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
        HStack(spacing: 10) {
            TerminalCommandField(
                text: $command,
                isFocused: $inputFocused,
                placeholder: "Send a command",
                isEnabled: canType,
                onSubmit: submit
            )
            // A `UITextField` has no intrinsic height, so the frame is here rather than inside the
            // representable — the same 30 points ``TerminalPanel`` gives it.
            .frame(height: 30)

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

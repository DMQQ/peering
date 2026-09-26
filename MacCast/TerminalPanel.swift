import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI

/// A deliberately small native terminal surface. The Mac owns the PTY and shell; this view only
/// displays its bounded byte history and sends exact input bytes over the authenticated session.
struct TerminalPanel: View {
    @Environment(SessionModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var command = ""
    /// The tab whose name is being typed, and what has been typed into it so far.
    @State var renamingID: UUID?
    @State var renameText = ""
    /// The terminal a close was asked for and not yet confirmed.
    @State var pendingClose: RemoteTerminal?
    /// Deliberately a plain state flag rather than a `@FocusState`, and this is the whole of why
    /// the keyboard used to shut on every letter typed.
    ///
    /// `@FocusState` is SwiftUI's storage for SwiftUI's own focus system: it expects a view to
    /// claim that focus through a `.focused()` modifier, and when nothing does it reconciles the
    /// value back to nil on the next update — which is the next keystroke, because a keystroke
    /// changes the text and re-renders this panel. The field here is a `UITextField` that owns its
    /// own responder status and reports it back through this binding, so SwiftUI had nothing to
    /// attribute the focus to and cleared it; `updateUIView` then saw "not focused" over a field
    /// that was first responder and resigned it. One letter, keyboard gone, every time.
    ///
    /// The rename field keeps `@FocusState`, because that one is a real SwiftUI `TextField` with a
    /// `.focused()` modifier and no such disagreement.
    @State var inputFocused = false
    @FocusState var renameFocused: Bool

    /// Whether the terminal's tips have been seen. See ``Tour``.
    ///
    /// The same flag ``SSHTerminalScreen`` reads, and the same steps: the deck and the command row
    /// are one set of controls shown on two screens. The log is not one of them — it belongs to
    /// the shell tour, which is the other screen's.
    @AppStorage(PreferenceKeys.hasSeenTourTerminal) var hasSeenTourTerminal = false

    /// The log's type size, which is also what decides how much of a shell fits across the screen.
    /// See ``TerminalMetrics/TextSize``. Both terminals read the same preference, so a size set in
    /// one is the size in the other.
    @AppStorage(PreferenceKeys.terminalTextSize) var textSize = TerminalMetrics.TextSize.regular.rawValue

    /// The same, as the number the layout wants.
    var fontSize: CGFloat { TerminalMetrics.TextSize.named(textSize).points }

    var dueTerminalTours: [Tour] {
        hasSeenTourTerminal ? [] : [.terminal]
    }

    /// Whether new output should pull the view down, or leave it where the user scrolled to.
    ///
    /// This panel had the same fault as the SSH one: `.defaultScrollAnchor(.bottom)` pins the
    /// anchor as content grows, so a program redrawing continuously dragged the view back to the
    /// bottom every time the finger lifted.
    @State var stickToBottom = true

    /// The commands both terminals keep one tap away. Owned by the app, because the SSH terminal
    /// shows the same list.
    @Environment(QuickCommands.self) var quickCommands
    @State var isEditingQuickCommands = false

    /// Whether the command history is showing. Off by default — see the button in ``input(_:)``.
    @State var showsHistory = false

    /// Whether the panel is showing the Mac's folders instead of the terminal.
    ///
    /// The terminal is not put away while this is on: it is still connected, still running, and
    /// still receiving output, and the panel is only showing something else. What the browser does
    /// to the shell is change its directory, and only when a folder is opened.
    @State var isBrowsing = false
    /// Whether dotfiles are listed. The panel filters them itself, so the Mac sends everything and
    /// both browsers this protocol serves can be shown the same.
    @State var showsHiddenFiles = false

    /// The folder the browser is showing, and `nil` for as long as that is still the Mac's home
    /// folder with its path not yet resolved — the one path this side cannot work out for itself.
    ///
    /// The model's, not the panel's: this panel is rebuilt every time it is opened, and the folder
    /// a Mac is being browsed at is not something that should be forgotten in between.
    var browsingPath: String? {
        guard let id = model.selectedTerminalID else { return nil }
        return model.browsingPath(for: id)
    }

    var selected: RemoteTerminal? {
        guard let id = model.selectedTerminalID else { return nil }
        return model.terminals.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The one place the end question is asked from, for the whole strip — see
                // ``terminalEndPrompt(_:name:detail:isPresented:onEnd:)`` for why it is asked
                // here rather than at the tab that was tapped. ``pendingClose`` says which tab.
                tabStrip
                    .terminalEndPrompt(
                        name: pendingClose?.name ?? "",
                        detail: "The shell running in it stops. Your Mac and the rest of the terminals are left alone.",
                        isPresented: Binding(
                            get: { pendingClose != nil },
                            set: { if !$0 { pendingClose = nil } }
                        ),
                        onEnd: {
                            guard let terminal = pendingClose else { return }
                            model.closeTerminal(terminal.id)
                            pendingClose = nil
                        }
                    )
                // No divider here. The strip draws its own rule along the bottom edge, behind
                // the tabs, and a system divider a point under that line was a second hairline
                // running across the seam the selected tab is supposed to be joined to.
                if let terminal = selected {
                    if isBrowsing {
                        browsing(terminal)
                    } else {
                        // No anchor on the output here: the log belongs to the shell tour, which is
                        // the SSH screen's, and this panel shows the terminal's two steps only.
                        output(terminal)
                        // Above the deck rather than in it, because it is not a chip you press to
                        // send something — it is a list of what has already been sent, and it is
                        // shown only while the button in the input row says so.
                        if showsHistory, !model.terminalHistory.isEmpty { historyStrip(terminal.id) }
                        // The saved commands and the keys, in one row — see ``TerminalDeck``.
                        //
                        // `self.` is load-bearing: unqualified, `send` here resolves to Darwin's
                        // POSIX `send(2)`, which is in scope through Foundation and takes a socket
                        // descriptor — so the closure compiled against the wrong function entirely.
                        TerminalDeck(
                            commands: quickCommands.all,
                            run: { model.sendTerminalInput($0.command, to: terminal.id) },
                            remove: { quickCommands.delete($0) },
                            // Making a command is Pro; running one the user already has, and the
                            // keys beside it, are not. The chips stay either way, so a plan that
                            // lapses takes away the editor and not the shortcuts somebody has
                            // been using every day. Which of the two the button opens is the
                            // deck's own gate (see ``TerminalDeck``, where the button is drawn
                            // once and the plan decides whether it is live).
                            edit: { isEditingQuickCommands = true },
                            send: { self.send($0, to: terminal.id) },
                            isEnabled: terminal.isRunning
                        )
                        .tourAnchor(.terminalDeck)
                        input(terminal)
                            .tourAnchor(.terminalInput)
                    }
                } else {
                    ContentUnavailableView(
                        "No terminals",
                        systemImage: "terminal",
                        // Two short sentences, because the question this answers is one line
                        // long. "Create a login shell" is the honest name for what the host
                        // starts and it explains nothing to anyone who has not already used
                        // one; the earlier attempt at explaining it took three lines to say
                        // what fits in one.
                        description: Text("Runs on your Mac, not here. It keeps going when you disconnect.")
                    )
                }
            }
            .background(Color.black)
            // The same three steps the SSH terminal shows, on the same three controls, because it
            // is the same terminal: one deck, one command field and one log, shared between the
            // Mac's shells and a server's. One flag between them too, so a person who has read
            // what the keys do on one of them is not told again on the other.
            .firstRunTours(dueTerminalTours) { $0.markSeen() }
            .navigationTitle("Mac terminals")
            .navigationBarTitleDisplayMode(.inline)
            // The header is part of the terminal, so it is the terminal's colour. Left alone it
            // is a system bar material, which over a black panel reads as a different app's
            // chrome sitting on top of this one.
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                // The switch between a terminal and the Mac's folders is not here. It is pinned to
                // the end of the tab strip — see ``TerminalModeButton`` for why the leading end of
                // a navigation bar turned out to be the wrong place for it.
                ToolbarItem(placement: .primaryAction) {
                    // One button and no menu. A new terminal is always a shell with no name:
                    // it is named by the first command run in it, or by hand on the tab, and
                    // neither of those is a question worth asking before the shell exists.
                    //
                    // **One button, drawn once, in both states.** The first shell is free on
                    // every plan, so this is only the paid thing once there is a shell to be
                    // concurrent with. That is the question ``SessionModel/canOpenAnotherShell``
                    // answers, and it is also what ``SessionModel/createTerminal()`` refuses on,
                    // so the button and the request cannot come apart.
                    //
                    // On a plan that has run out of shells the plus is still a plus, dimmed, with
                    // the plan's name on its corner rather than a padlock in its place. This button is
                    // how somebody finds out the app can keep several shells open at all, and a
                    // padlock where the plus was is the one drawing that answers "what does this
                    // button do" with nothing.
                    PlanLocked(
                        capability: .shellTabs,
                        title: "New terminal",
                        diameter: 20,
                        isIncluded: model.canOpenAnotherShell
                    ) {
                        Button { model.createTerminal() } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New terminal")
                    }
                }
                // The keyboard's own bar, which is where iOS puts a dismiss key and therefore
                // where the hand looks for one. It also puts it a keyboard's height away from
                // send, which the row above could not. A name being typed is committed by the
                // same key, because letting go of the field is what says the name is finished.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        renameFocused = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshTerminals() }
        // Switching tabs while the browser is open looks at the same folder in the other shell.
        // The folder is where the user is looking, not something a terminal owns, and a browser
        // that silently kept the old shell's listing would be showing another Mac's folders.
        .onChange(of: model.selectedTerminalID) { _, id in
            guard isBrowsing, let id,
                  model.terminals.first(where: { $0.id == id })?.isRunning == true else { return }
            model.listDirectory(browsingPath, sessionID: id)
        }
        .sheet(isPresented: $isEditingQuickCommands) {
            SSHQuickCommandsEditor(commands: quickCommands)
        }
    }

    /// Names a tab, in the tab.
    ///
    /// The name starts as what the tab is already called, so the common edit is one word changed
    /// rather than a name remembered. Emptying it is meaningful: the Mac reads an empty name as
    /// "stop calling it that" and goes back to naming the terminal after what is run in it.
    func beginRename(_ terminal: RemoteTerminal) {
        model.selectTerminal(terminal.id)
        renameText = terminal.name
        renamingID = terminal.id
        // A turn later, because the field has to exist before it can take focus — set in the
        // same pass there is nothing to focus and the keyboard never comes up.
        Task { @MainActor in renameFocused = true }
    }

    func renameField(_ terminal: RemoteTerminal) -> some View {
        TextField("Name", text: $renameText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(ColorPalette.ink)
            .focused($renameFocused)
            .submitLabel(.done)
            .onSubmit { commitRename(terminal.id) }
            // Wide enough for a word, not for a command: a name is being typed here, and a tab
            // that grew to fit every letter of one is a tab that pushed the others off screen.
            .frame(width: 116)
            // Letting go of the field is how a name is finished. There is nothing else to press,
            // and a field left open on a tab that then scrolls out of reach is a name nobody can
            // commit.
            .onChange(of: renameFocused) { _, focused in
                if !focused { commitRename(terminal.id) }
            }
    }

    func commitRename(_ id: UUID) {
        // Cleared first, so the focus change that follows — this sets the flag the field watches
        // — finds nothing left to commit and stops here rather than sending the name twice.
        guard renamingID == id else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        renameText = ""
        renameFocused = false
        model.renameTerminal(id, to: name)
    }

    /// The open terminals, as tabs.
    ///
    /// A row of names on the panel's own black, with a rule under the one you are in. Not shapes
    /// standing on the page: a tab drawn as a lid raised above the content's flat edge is a bump
    /// however it is coloured, and a strip of two of them reads as something surfacing out of the
    /// panel rather than as the page's own header. The row is joined to the page instead — one
    /// black, no seam — and the mark for where you are is a rule *inside* the row rather than a
    /// shape outside it.
    ///
    /// **One height for every tab**, which is the other half of the same fix. The tab in front used
    /// to be the taller one, and that is what made the strip read as three-dimensional: whatever
    /// grows upward out of its own row is a lump in it. What says which one is on now is ink (the
    /// name at full brightness against the others' half) and the rule under it.
    ///
    /// The name on a tab is a working title — the last command run there, or a name typed onto
    /// the tab itself — so the strip has to hold names of any length and stay readable while
    /// they change under it.
    var tabStrip: some View {
        TabStrip(items: model.terminals, selection: model.selectedTerminalID) { terminal, isSelected in
            chip(terminal, isSelected: isSelected)
        } accessory: {
            // The switch to the Mac's folders, pinned outside the scroller so that it is in the
            // same place however many terminals are open — see ``TerminalModeButton`` for why it
            // is on this row rather than in the navigation bar it used to sit in.
            //
            // Drawn only when there is a terminal to browse, which was the condition on the
            // toolbar item this replaced: with nothing selected there is no shell to change
            // directory, so the browser would have nothing to look at.
            //
            // The 11 points of top padding centre the chip on the tab names rather than on the
            // tab: a tab is a 32-point name row starting 8 points down with its rule and its
            // clearance below, and the strip is 47 points tall. Centred in the strip the chip
            // would sit five points low, under the names it is a sibling of.
            if let terminal = selected {
                TerminalModeButton(isBrowsing: isBrowsing) { toggleBrowsing(terminal) }
                    .padding(.top, 11)
                    .padding(.trailing, 8)
            }
        }
    }

    /// Closing a terminal, with a question when there is something to lose.
    ///
    /// Empty is not a description of the tab, it is the answer to "would anything be lost" — and a
    /// shell with nothing printed in it yet is still a shell, killed by the same tap. So anything
    /// running, or anything that has said something, is asked about; a terminal that stopped on
    /// its own and printed nothing goes without ceremony, because there is nothing there to close.
    func requestClose(_ terminal: RemoteTerminal) {
        if terminal.isRunning || !terminal.output.isEmpty {
            pendingClose = terminal
        } else {
            model.closeTerminal(terminal.id)
        }
    }

    func chip(_ terminal: RemoteTerminal, isSelected: Bool) -> some View {
        let state = terminal.state
        let isRenaming = renamingID == terminal.id
        // No cross while a name is being typed. The field is what the tab is for then, and a
        // control that ends the shell sitting beside a field somebody is typing into is a mis-tap
        // waiting for a thumb that is already moving.
        let onClose: (() -> Void)? = isRenaming ? nil : { requestClose(terminal) }

        return TabChip(
            isSelected: isSelected,
            onSelect: { model.selectTerminal(terminal.id) },
            onClose: onClose,
            // The cross is on the tab, where the SSH terminal puts it.
            //
            // It lived outside the scroller for a while, on the good argument that a control
            // which destroys something should not move about — a row of names of different
            // lengths is a row of crosses at different distances. What that traded away turned out
            // to cost more: the fixed button closes whichever terminal is *selected*, so the cross
            // you are pointing at and the terminal you are closing are two different things, and a
            // close that has to be found reads as no close at all. The long press still closes any
            // tab by name.
            closeLabel: "Close \(terminal.name)"
        ) {
            mark(for: state)
        } name: {
            if isRenaming {
                renameField(terminal)
            } else {
                TabName(
                    text: terminal.name,
                    isSelected: isSelected,
                    colour: nameColour(for: state, isSelected: isSelected)
                )
            }
        }
        // Selecting and renaming share the tab, and a double tap on it is what renames.
        //
        // Simultaneous rather than a pair of counted taps. Counted, the single tap has to wait
        // out the double-tap window before it fires, and a tab strip that takes a third of a
        // second to answer a thumb is worse than one where the second tap of a double selects
        // again — which is idempotent, and therefore free.
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(terminal) })
        // And on a long press, because a double tap is a desktop habit with nothing on screen
        // to announce it.
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(terminal) }
                .menuInk()
            Button("Close", systemImage: "xmark", role: .destructive) { requestClose(terminal) }
                .menuDanger()
        }
    }

    /// The line between one band of the panel and the next.
    ///
    /// The panel is five strips stacked — the tabs, the output, the history, the keys, the input —
    /// and without a line between them they read as one undifferentiated black column with
    /// controls floating in it. Which band a thing belongs to is most of what there is to know
    /// about this screen: the keys send bytes and the input sends a line, and the two loose
    /// strips at the bottom sitting against each other with nothing between them is what made
    /// that hard to see.
    ///
    /// One line and one weight for every seam, because these are one object cut into strips. A
    /// seam a point heavier in one place than another is the kind of thing that reads as sloppy
    /// without anyone being able to say why.
    var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    /// The one mark a tab carries.
    ///
    /// Every state that has something to say says it here: a spinner while the shell is still
    /// coming up, a lock when the Mac is asking for a password, a question mark when it is asking
    /// for a yes or a no, and a warning when something asked of the terminal did not work. The two
    /// states with nothing to say get the terminal glyph, which is the mark the slot carries when
    /// it is not reporting anything — so a tab is recognisable as a terminal before it is
    /// recognisable as a state, and the names in the strip do not shuffle sideways as the marks in
    /// front of them come and go.
    @ViewBuilder
    func mark(for state: TerminalState) -> some View {
        switch state {
        case .starting:
            ProgressView()
                .controlSize(.mini)
                .tint(.secondary)
        case .attention(let kind):
            Image(systemName: kind == .password ? "lock.fill" : "questionmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.danger)
        // A terminal glyph, which is what the two quiet states have instead of nothing. Every tab
        // in the strip starts with the same mark, so the slot reads as "a terminal" first and as a
        // *state* only when there is one — and a row of names where only the interesting ones have
        // a glyph in front of them is a row that shifts under its own tab names as states change.
        case .running:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.ink.opacity(0.3))
        }
    }

    /// What colour a tab's name is written in.
    ///
    /// A state's tint wins over the selection, and it has to: "this terminal wants your password"
    /// is the one thing on the strip that has to be found at a glance, and a selected tab that had
    /// gone quiet would be the one place it could be missed. Colour is the exception the palette
    /// allows and this is where it is spent.
    func nameColour(for state: TerminalState, isSelected: Bool) -> Color {
        if let tint = state.tint { return tint }
        if state == .stopped { return ColorPalette.ink.opacity(0.3) }
        return isSelected ? ColorPalette.ink : Color.secondary
    }

    /// The output, or what stands in for it while the Mac starts the shell.
    ///
    /// A `ZStack` rather than a `Group`, so that the two states are two views a container can
    /// cross-fade between rather than two branches of an `if` with nothing around them to animate.
    func output(_ terminal: RemoteTerminal) -> some View {
        ZStack {
            if terminal.output.isEmpty, terminal.isRunning {
                TerminalStarting()
                    .transition(.opacity)
            } else {
                log(terminal)
                    .transition(.opacity)
            }
        }
        .animation(Motion.tap, value: terminal.output.isEmpty)
    }

    func log(_ terminal: RemoteTerminal) -> some View {
        ScrollViewReader { reader in
            // Two scroll views rather than one with two axes, and that is the whole of why the
            // output stops dragging itself sideways.
            //
            // `scrollTo(id, anchor: .bottom)` pins the target's *bottom* to the viewport's
            // bottom — and on a two-axis scroll view it does the same thing horizontally, so
            // every new line of output walked the view to the right. Nested, the outer one owns
            // the vertical and can follow the tail of the log on its own, while the inner one
            // holds whatever the finger left it at and starts where reading starts: the left.
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(coloured(terminal))
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        // The lines are as wide as they are. Wrapping them would be the other way
                        // to keep the view still, and it ruins the one thing a terminal is good
                        // at — output that lines up in columns.
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                // The thing the vertical scroll follows. A one-point view at the end of the text
                // rather than an anchor on the text itself: the text is as wide as the widest
                // line, and anchoring to it is what dragged the view sideways.
                Color.clear.frame(height: 1).id("terminal-end")
            }
            // Whether the picture follows new output or stays where the user put it — a terminal
            // sticks to the bottom until you scroll up, and then it leaves you alone until you
            // come back down. `.defaultScrollAnchor(.bottom)` was here instead, and it pins the
            // anchor as content grows, so every redraw dragged the view back down.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let fromBottom = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return fromBottom <= Self.bottomSlack
            } action: { _, atBottom in
                stickToBottom = atBottom
            }
            // Dragging the history puts the keyboard away. The alternative is a keyboard with no
            // dismiss key that covers the bottom half of a panel whose whole point is the text
            // above it, and the only way out is leaving the screen.
            .scrollDismissesKeyboard(.interactively)
            // Pressing the output is pressing the prompt. A terminal on a phone is read by
            // looking at the bottom of it, and what the thumb does next is type a command — so
            // the tap goes where the typing goes rather than doing nothing. The text stays
            // selectable by long press, which is the gesture that asked for it.
            .onTapGesture { inputFocused = true }
            .onChange(of: terminal.output.count) { _, _ in
                guard stickToBottom else { return }
                reader.scrollTo("terminal-end", anchor: .bottom)
            }
            .task {
                reader.scrollTo("terminal-end", anchor: .bottom)
            }
            .background {
                // The Mac is told how big the terminal is. `resizeTerminal` has existed all along
                // and was called from nowhere, so every shell on this side ran at the 80×24 a PTY
                // defaults to — `vim` and `top` laid out for a window that did not exist.
                // Measured on the log rather than the panel, because the key strip and the input
                // row are not part of what the shell gets to draw on.
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        applySize(size, to: terminal)
                    }
                }
            }
        }
    }

    /// How close to the bottom still counts as being at the bottom.
    ///
    /// Not zero, because a scroll view rarely lands exactly on the edge and a terminal that stops
    /// following output because it is 2 points short of the end is worse than one that follows
    /// slightly too eagerly.
    static let bottomSlack: CGFloat = 24

    /// Character cells, from the measured size of the log. See ``TerminalMetrics``.
    ///
    /// Reported rather than kept: the grid a shell is drawn on belongs to the shell, and the rows
    /// only ever grow there, which is what keeps the keyboard from resizing a terminal. See
    /// ``MacSession/resizeTerminal(_:columns:rows:)``.
    func applySize(_ size: CGSize, to terminal: RemoteTerminal) {
        guard size.width > 0, size.height > 0 else { return }
        model.resizeTerminal(
            terminal.id,
            columns: TerminalMetrics.columns(forWidth: size.width, fontSize: fontSize),
            rows: TerminalMetrics.rows(forHeight: size.height, fontSize: fontSize)
        )
    }

    /// The history, with the colours the shell asked for.
    ///
    /// Run through ``TerminalScreen`` rather than the line-based ``TerminalTextSanitizer``, which
    /// is the same change the SSH terminal needed and for the same reason: a renderer that
    /// discards cursor addressing cannot draw a program that positions, so `htop` came out as
    /// every frame it had ever painted, replayed in order and overwriting itself. It also brings
    /// the shell's own colours, which this panel did not show at all — the only colour here was
    /// a heuristic that scans a line for the word "error".
    ///
    /// Both panels now go through one renderer, so a colour means the same thing in each.
    func coloured(_ terminal: RemoteTerminal) -> AttributedString {
        guard !terminal.output.isEmpty else {
            // Only reached by a terminal that stopped without printing anything — the running and
            // empty case is ``TerminalStarting``, which is drawn rather than written. "Starting
            // login shell…" was here for both, and it sat on screen for a shell that had already
            // exited, saying something that was no longer true.
            return AttributedString(terminal.isRunning ? "Starting login shell…" : "Nothing was printed.")
        }

        return TerminalPalette.attributed(terminal.screen.styled, fontSize: fontSize)
    }

    /// What has been run here before, newest first, one tap from the field.
    ///
    /// Only the commands, and only what was typed: the PTY hands back a byte stream with no
    /// notion of where one command's output ended and the next prompt began, so "the result of
    /// that command" is not something this side can know. Re-running is, and it is the part that
    /// saves typing — results are already on screen above.
    ///
    /// A tap puts the command in the field rather than sending it. A list that runs things when
    /// you touch it is a list you cannot browse on a phone.
    func historyStrip(_ id: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ForEach(model.terminalHistory, id: \.self) { command in
                    Button {
                        self.command = command
                        inputFocused = true
                    } label: {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!(selected?.isRunning ?? false))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .top) { hairline }
    }

    func input(_ terminal: RemoteTerminal) -> some View {
        HStack(spacing: 8) {
            // Leftmost: keyboard dismiss — the far end of the row from send so the two actions
            // cannot be confused. Always shown so there is no layout jump as focus changes.
            //
            // Drawn as a key rather than as a bare glyph, which is what it is, and the same key in
            // a server's terminal: the two are one control on two screens. See
            // ``TerminalHideKeyboardKey``.
            TerminalHideKeyboardKey {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }

            // The history, one tap from the field it fills.
            //
            // It used to be a strip of its own, always up, under the output — which along with
            // the quick commands and the keys made three horizontal scrollers stacked beneath the
            // text. The history is the one of the three that is only wanted at the moment of
            // typing, so it is the one that waits to be asked for. Shown only once there is
            // something in it: a control that reveals an empty list teaches nothing the first
            // time it is pressed.
            if !model.terminalHistory.isEmpty {
                Button {
                    withAnimation(Motion.tap) { showsHistory.toggle() }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showsHistory ? ColorPalette.accent : Color.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsHistory ? "Hide command history" : "Show command history")
            }

            TerminalCommandField(
                text: $command,
                isFocused: Binding(
                    get: { inputFocused },
                    set: { inputFocused = $0 }
                ),
                placeholder: terminal.isRunning ? "Type a command" : "Process exited",
                isEnabled: terminal.isRunning,
                onSubmit: { submit(to: terminal.id) }
            )
            // A height, not a minimum, and that is not tidiness either. A `UITextField` has no
            // intrinsic height that SwiftUI will hold it to, so given `minHeight` this row grew to
            // whatever it was offered: the stack had surplus space, the scroll view above took
            // some of it and this took the rest, and the field's contents sat centred in a band
            // 328 points tall, 37% of the screen, with black above and below. Measured on a
            // screenshot from the phone, which is the only reason it was ever diagnosed: it looks
            // like a gap in the layout, not like a text field that came out too big.
            .frame(height: TerminalCommandField.height)
            Button { submit(to: terminal.id) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!terminal.isRunning || command.isEmpty)
        }
        // Away from the edge. At 10 the field's text started close enough to the screen's edge
        // that the caret sat against it, which reads as clipped rather than as inset.
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // The terminal's own black, with a rule above it. It was a material, which put a grey
        // band across the bottom of a black panel and read as chrome from a different app.
        .background(Color.black)
        .overlay(alignment: .top) { hairline }
    }
}

import RemoteCore
import SwiftUI

/// A deliberately small native terminal surface. The Mac owns the PTY and shell; this view only
/// displays its bounded byte history and sends exact input bytes over the authenticated session.
struct TerminalPanel: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    /// The tab whose name is being typed, and what has been typed into it so far.
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var inputFocused: Bool
    @FocusState private var renameFocused: Bool

    private var selected: RemoteTerminal? {
        guard let id = model.selectedTerminalID else { return nil }
        return model.terminals.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabStrip
                // No divider here. The strip draws its own rule along the bottom edge, behind
                // the tabs, and a system divider a point under that line was a second hairline
                // running across the seam the selected tab is supposed to be joined to.
                if let terminal = selected {
                    output(terminal)
                    if !model.terminalHistory.isEmpty { historyStrip(terminal.id) }
                    keyStrip(terminal.id)
                    input(terminal)
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
                ToolbarItem(placement: .primaryAction) {
                    // One button and no menu. A new terminal is always a shell with no name:
                    // it is named by the first command run in it, or by hand on the tab, and
                    // neither of those is a question worth asking before the shell exists.
                    Button { model.createTerminal() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New terminal")
                }
                // The keyboard's own bar, which is where iOS puts a dismiss key and therefore
                // where the hand looks for one. It also puts it a keyboard's height away from
                // send, which the row above could not. A name being typed is committed by the
                // same key, because letting go of the field is what says the name is finished.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        inputFocused = false
                        renameFocused = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshTerminals() }
    }

    /// Names a tab, in the tab.
    ///
    /// The name starts as what the tab is already called, so the common edit is one word changed
    /// rather than a name remembered. Emptying it is meaningful: the Mac reads an empty name as
    /// "stop calling it that" and goes back to naming the terminal after what is run in it.
    private func beginRename(_ terminal: RemoteTerminal) {
        model.selectTerminal(terminal.id)
        renameText = terminal.name
        renamingID = terminal.id
        // A turn later, because the field has to exist before it can take focus — set in the
        // same pass there is nothing to focus and the keyboard never comes up.
        Task { @MainActor in renameFocused = true }
    }

    private func renameField(_ terminal: RemoteTerminal) -> some View {
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

    private func commitRename(_ id: UUID) {
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
    private var tabStrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.terminals) { terminal in
                        tab(terminal).id(terminal.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            // The seam the row stands on, across the whole panel and behind the tabs rather than
            // among them: drawn inside the scrolled stack it was only as wide as the tabs were and
            // slid along with them, which is a rule drawn on the tabs and not the edge under them.
            .background(alignment: .bottom) { hairline }
            // A new terminal arrives at the far end of the strip, and a terminal that wants you
            // is somewhere you were not looking. Both are worth being shown rather than hunted
            // for, and both are things this selection is what changes.
            .onChange(of: model.selectedTerminalID) { _, id in
                guard let id else { return }
                withAnimation(Motion.settle) { reader.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func tab(_ terminal: RemoteTerminal) -> some View {
        let isSelected = model.selectedTerminalID == terminal.id
        let state = terminal.state
        let isRenaming = renamingID == terminal.id
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                mark(for: state)

                if isRenaming {
                    renameField(terminal)
                } else {
                    Text(terminal.name)
                        // Monospaced, because most of the time this is a command, and the strip is
                        // read by shape the way a command is.
                        .font(.system(
                            size: 12.5,
                            weight: isSelected ? .semibold : .regular,
                            design: .monospaced
                        ))
                        .foregroundStyle(nameColour(for: state, isSelected: isSelected))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // On the tab you are in and nowhere else — the close action belongs to the page you
                // are looking at, and a cross on every tab is a row of little forms to fill in. Not
                // while a name is being typed either: the field is the whole of what that tab is
                // doing, and a cross beside a caret is a thing to hit by accident.
                if isSelected && !isRenaming {
                    Button {
                        model.closeTerminal(terminal.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(terminal.name)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(
                minWidth: 88,
                // Capped, because the name is a command and commands are long. Uncapped while a
                // name is being typed, since the field has a width of its own to be given.
                maxWidth: isRenaming ? nil : 190,
                alignment: .leading
            )

            // The rule, under the tab rather than around it, and clear of its ends so it reads as
            // sitting on the seam rather than as the tab being boxed in. Ink rather than the
            // accent: blue is this app's "something here wants you" — a lock, a question, a
            // failure — and a tab would wear the same blue for two different reasons.
            Capsule()
                .fill(isSelected ? ColorPalette.ink : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, 9)
                .padding(.bottom, 5)
        }
        .contentShape(Rectangle())
        // Selecting and renaming share the tab, and a double tap on it is what renames.
        //
        // Simultaneous rather than a pair of counted taps. Counted, the single tap has to wait
        // out the double-tap window before it fires, and a tab strip that takes a third of a
        // second to answer a thumb is worse than one where the second tap of a double selects
        // again — which is idempotent, and therefore free.
        .onTapGesture { model.selectTerminal(terminal.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(terminal) })
        // And on a long press, because a double tap is a desktop habit with nothing on screen
        // to announce it.
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(terminal) }
            Button("Close", systemImage: "xmark", role: .destructive) {
                model.closeTerminal(terminal.id)
            }
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
    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    /// The one mark a tab carries.
    ///
    /// Every state that has something to say says it here, and the rest have nothing — a mark
    /// on every tab would be a mark that means nothing. What appears is the state in one glance:
    /// a spinner while the shell is still coming up, a lock when the Mac is asking for a
    /// password, a question mark when it is asking for a yes or a no, and a warning when
    /// something asked of the terminal did not work.
    @ViewBuilder
    private func mark(for state: TerminalState) -> some View {
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
        case .running, .stopped:
            EmptyView()
        }
    }

    /// What colour a tab's name is written in.
    ///
    /// A state's tint wins over the selection, and it has to: "this terminal wants your password"
    /// is the one thing on the strip that has to be found at a glance, and a selected tab that had
    /// gone quiet would be the one place it could be missed. Colour is the exception the palette
    /// allows and this is where it is spent.
    private func nameColour(for state: TerminalState, isSelected: Bool) -> Color {
        if let tint = state.tint { return tint }
        if state == .stopped { return ColorPalette.ink.opacity(0.3) }
        return isSelected ? ColorPalette.ink : Color.secondary
    }

    private func output(_ terminal: RemoteTerminal) -> some View {
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
                        .font(.system(size: 12, design: .monospaced))
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
            .defaultScrollAnchor(.bottom)
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
                reader.scrollTo("terminal-end", anchor: .bottom)
            }
        }
    }

    /// The history, with the lines that look like failures coloured.
    ///
    /// A terminal on a phone is read by scrolling past things, and what you are scrolling past
    /// for is the line that says why nothing worked. Two colours, both dimmer than the text
    /// around them so they mark a line rather than shout about it — and a `Text` that is one
    /// attributed string rather than a stack of coloured rows, because the selection and the
    /// copy behaviour are what a terminal is for.
    private func coloured(_ terminal: RemoteTerminal) -> AttributedString {
        guard !terminal.output.isEmpty else {
            return AttributedString("Starting login shell…")
        }
        var output = AttributedString()
        for line in TerminalTextSanitizer.renderLines(terminal.output) {
            var piece = AttributedString(line.text)
            switch line.kind {
            case .error:
                piece.foregroundColor = ColorPalette.danger
            case .warning:
                piece.foregroundColor = ColorPalette.caution
            case .plain:
                break
            }
            piece.append(AttributedString("\n"))
            output.append(piece)
        }
        return output
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
    private func historyStrip(_ id: UUID) -> some View {
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

    private func input(_ terminal: RemoteTerminal) -> some View {
        HStack(spacing: 8) {
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
            .frame(minHeight: 22)
            Button { submit(to: terminal.id) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!terminal.isRunning || command.isEmpty)
            // The keyboard's dismiss key is in the keyboard's own toolbar — see `body`. It used
            // to be a second button here, half an inch from send, and two buttons of different
            // meaning that close together is a row you have to aim in.
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

    /// The keys a terminal needs and a phone keyboard has not got.
    ///
    /// Drawn like the session's own rail buttons — glass, the same corner, the same press — rather
    /// than as bordered system buttons. It is the same kind of control in the same place on the
    /// screen as the rail, and two visual languages for one idea, an app apart, is what makes the
    /// second screen feel like somebody else's.
    private func keyStrip(_ id: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Editing and the shell's own control keys first, then a group of navigation
                // keys, then the two that end a line. The order is the order they are reached
                // for: ⌃C is the one key a phone terminal cannot do without, and it should never
                // be a scroll away.
                terminalKey("esc", label: "Escape") { send("\u{1B}", to: id) }
                terminalKey("tab", label: "Tab") { send("\t", to: id) }
                terminalKey("⇧tab", label: "Back tab") { send("\u{1B}[Z", to: id) }
                terminalKey("⌃C", label: "Interrupt") { send("\u{03}", to: id) }
                terminalKey("⌃D", label: "End of input") { send("\u{04}", to: id) }
                terminalKey("⌃Z", label: "Suspend") { send("\u{1A}", to: id) }
                terminalKey("⌃L", label: "Clear screen") { send("\u{0C}", to: id) }
                terminalKey("⌃R", label: "Search history") { send("\u{12}", to: id) }
                terminalKey("⌃A", label: "Start of line") { send("\u{01}", to: id) }
                terminalKey("⌃E", label: "End of line") { send("\u{05}", to: id) }
                terminalKey("⌃K", label: "Delete to end of line") { send("\u{0B}", to: id) }
                terminalKey("⌃U", label: "Delete to start of line") { send("\u{15}", to: id) }
                terminalKey("⌃W", label: "Delete word before") { send("\u{17}", to: id) }

                divider

                terminalKey("↑", label: "Up") { send("\u{1B}[A", to: id) }
                terminalKey("↓", label: "Down") { send("\u{1B}[B", to: id) }
                terminalKey("←", label: "Left") { send("\u{1B}[D", to: id) }
                terminalKey("→", label: "Right") { send("\u{1B}[C", to: id) }
                // Word at a time. Option rather than Control because that is what macOS
                // Terminal binds, and the escape sequences it produces are what bash and zsh
                // read as "a word" — ⌃← would move by a word in some shells and by a character
                // in others.
                terminalKey("⌥←", label: "Word left") { send("\u{1B}b", to: id) }
                terminalKey("⌥→", label: "Word right") { send("\u{1B}f", to: id) }
                terminalKey("home", label: "Home") { send("\u{1B}[H", to: id) }
                terminalKey("end", label: "End") { send("\u{1B}[F", to: id) }
                terminalKey("pg↑", label: "Page up") { send("\u{1B}[5~", to: id) }
                terminalKey("pg↓", label: "Page down") { send("\u{1B}[6~", to: id) }

                divider

                terminalKey("ins", label: "Insert") { send("\u{1B}[2~", to: id) }
                terminalKey("del", label: "Delete forward") { send("\u{1B}[3~", to: id) }
                terminalKey("⌫", label: "Backspace") { send("\u{7F}", to: id) }
                terminalKey("return", label: "Return") { send("\r", to: id) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .top) { hairline }
    }

    /// Between the groups in the key strip. The strip is long now, and a wall of thirty keys is
    /// one a thumb has to read from the left every time; three groups of them, split by what they
    /// are for, is a strip where you know roughly how far to travel.
    private var divider: some View {
        Rectangle()
            .frame(width: 1, height: 22)
            .foregroundStyle(.white.opacity(0.15))
            .padding(.horizontal, 2)
    }

    /// Sends bytes, which is all any of these keys do.
    private func send(_ text: String, to id: UUID) {
        model.sendTerminalBytes(Array(text.utf8), to: id)
    }

    private func terminalKey(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                // Monospaced, because these are the characters the shell prints rather than
                // words: "esc" and "tab" line up with the arrows beside them, and "⌃C" is the
                // same glyph the control bar's caption uses for the same key.
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(ColorPalette.ink)
                .frame(minWidth: 46)
                .frame(height: 40)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel(label)
    }

    private func submit(to id: UUID) {
        guard !command.isEmpty else { return }
        model.sendTerminalInput(command, to: id)
        command = ""
        inputFocused = true
    }
}

/// A terminal command field whose Return key is handled without resigning first responder. SwiftUI
/// TextField's submit action dismisses the keyboard before its callback, which creates a visible
/// close/reopen cycle even when focus is immediately restored.
private struct TerminalCommandField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .send
        field.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        field.textColor = .white
        field.tintColor = .white
        field.clearButtonMode = .never
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.isEnabled = isEnabled
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalCommandField

        init(_ parent: TerminalCommandField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        // Feed UIKit focus events back into the SwiftUI binding. Without these, updateUIView
        // sees isFocused=false on the re-render that immediately follows a keystroke (because
        // SwiftUI re-renders on text change before the binding reflects the field's focus), and
        // calls resignFirstResponder() — which is why the keyboard closes on the first letter.
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

private extension TerminalState {
    /// The colour a tab wears for this state, or nothing for the states that are not asking for
    /// anything — those are drawn in the strip's own greys.
    ///
    /// Brightness is the palette's rule and hue is its exception, and this is the second place
    /// the exception is earned. A tab is 12 points of monospaced text in a row of near-identical
    /// ones, and three shades of white at arm's length are one shade: "this terminal wants a
    /// password" has to be findable at a glance or it is decoration.
    var tint: Color? {
        switch self {
        case .attention: return ColorPalette.accent
        case .failed: return ColorPalette.danger
        case .starting, .running, .stopped: return nil
        }
    }
}

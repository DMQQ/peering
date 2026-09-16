import RemoteCore
import SwiftUI

/// A deliberately small native terminal surface. The Mac owns the PTY and shell; this view only
/// displays its bounded byte history and sends exact input bytes over the authenticated session.
struct TerminalPanel: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var newName = ""
    @State private var isCreating = false
    @FocusState private var inputFocused: Bool
    @FocusState private var createFocused: Bool

    private var selected: RemoteTerminal? {
        guard let id = model.selectedTerminalID else { return nil }
        return model.terminals.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabStrip
                Divider().opacity(0.35)
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
                // At the bottom, over the input it belongs to. It was at the top, under the tab
                // strip, which put the thing being named as far from the keyboard naming it as
                // the screen allows.
                if isCreating {
                    createRow
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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.refreshTerminals() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    // A menu rather than a button, because there are two ways to open a shell
                    // and only one of them wants a name: the common case is a terminal to type
                    // in, which the Mac will call Terminal 1, 2, 3 on its own. The other case is
                    // a terminal you want to find again later among five others, and that one is
                    // worth a word — often the last command, which is what the field starts with.
                    Menu {
                        Button("New terminal", systemImage: "plus") {
                            model.createTerminal(name: "")
                        }
                        Button("New named terminal…", systemImage: "textformat") {
                            beginCreating()
                        }
                    } label: {
                        Image(systemName: isCreating ? "xmark" : "plus")
                    }
                    .disabled(isCreating)
                    .accessibilityLabel("New terminal")
                }
                // The keyboard's own bar, which is where iOS puts a dismiss key and therefore
                // where the hand looks for one. It also puts it a keyboard's height away from
                // send, which the row above could not.
                //
                // While a terminal is being named it offers Create instead, because this bar sits
                // exactly where the create row's own button is — the row is at the bottom of the
                // panel and the keyboard lands on top of it, so the button under the thumb was
                // the one being covered. The only way to create was Return.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    if isCreating {
                        Button("Create") { create() }
                            .font(.system(size: 16, weight: .semibold))
                    } else {
                        Button("Done") { inputFocused = false }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshTerminals() }
    }

    /// Naming a terminal, in the panel rather than in a dialog over it.
    ///
    /// It was an alert with a text field in it, which is a lot of ceremony for one short name —
    /// and it arrives on top of the panel, hiding the thing being created, to ask a question
    /// about it. In the panel it is a line that appears where the terminal will be, with the
    /// keyboard already up.
    private var createRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ColorPalette.accent)
            TextField("Terminal \(model.terminals.count + 1)", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .focused($createFocused)
                .submitLabel(.go)
                .onSubmit { create() }
            Button("Create") { create() }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // The same material the input row below it wears, so the two read as one block that
        // appeared under the terminal rather than as a banner across it.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
        // No transition, and deliberately. It slides in and the keyboard slides up over the same
        // half second, which is two things animating one layout — the row jitters as the keyboard
        // takes the space it was moving into. In one frame, and the keyboard's own animation is
        // the only movement there is.
    }

    private func beginCreating() {
        if isCreating {
            isCreating = false
            newName = ""
            createFocused = false
            return
        }
        // Started on the last command, because that is the name most people would have chosen:
        // a shell opened to run something is remembered by what it ran.
        newName = model.terminalHistory.first ?? ""
        isCreating = true
        // A turn later, because the field has to exist before it can take focus — set in the same
        // pass, there is nothing to focus and the keyboard never comes up.
        Task { @MainActor in createFocused = true }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // No name is a name: the host falls back to "Terminal N", which is a better answer than
        // refusing to start a shell over a label.
        model.createTerminal(name: name)
        newName = ""
        isCreating = false
        createFocused = false
    }

    /// The open terminals, as tabs.
    ///
    /// A tab is not a chip. What makes one read as a tab is that it belongs to the thing below
    /// it: the tab you are in is drawn in the *content's* colour, joined to it along the bottom
    /// edge, so the page looks like it is coming up out of the tab — and the ones you are not in
    /// sit behind it, shorter, on the other side of a hairline. Capsules with a name in them are
    /// buttons, however they are labelled, and that is what this kept being.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(model.terminals) { terminal in
                    tab(terminal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // The rule the tabs stand on. The selected tab is drawn over it and in the content's
            // own black, which is the seam that makes the two one object.
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
        }
    }

    private func tab(_ terminal: RemoteTerminal) -> some View {
        let isSelected = model.selectedTerminalID == terminal.id
        // Rounded at the top only, and flat along the bottom where it meets the content.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 10,
            topTrailingRadius: 10,
            style: .continuous
        )
        return HStack(spacing: 7) {
            Text(terminal.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? ColorPalette.ink : Color.secondary)
                .lineLimit(1)

            if terminal.attention != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            // On the tab you are in and nowhere else — the close action belongs to the page you
            // are looking at, and a cross on every tab is a row of little forms to fill in.
            if isSelected {
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
        .padding(.leading, 13)
        .padding(.trailing, isSelected ? 5 : 13)
        // The tab in front is taller than the ones behind it, which is how a tab bar says where
        // you are without a legend.
        .frame(height: isSelected ? 38 : 32)
        .frame(minWidth: isSelected ? 112 : 78, alignment: .leading)
        .background(
            isSelected ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color.white.opacity(0.05)),
            in: shape
        )
        .overlay {
            shape.strokeBorder(
                isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.07),
                lineWidth: 1
            )
        }
        .contentShape(shape)
        .onTapGesture { model.selectTerminal(terminal.id) }
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
                piece.foregroundColor = Color(red: 0.98, green: 0.45, blue: 0.40)
            case .warning:
                piece.foregroundColor = Color(red: 0.97, green: 0.75, blue: 0.35)
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
    }

    private func input(_ terminal: RemoteTerminal) -> some View {
        HStack(spacing: 8) {
            TextField(terminal.isRunning ? "Type a command" : "Process exited", text: $command)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit(to: terminal.id) }
                .disabled(!terminal.isRunning)
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
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
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

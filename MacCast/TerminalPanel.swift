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
                if isCreating {
                    createRow
                    Divider().opacity(0.35)
                }
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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.refreshTerminals() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button { beginCreating() } label: {
                        Image(systemName: isCreating ? "xmark" : "plus")
                    }
                    .accessibilityLabel(isCreating ? "Cancel new terminal" : "New terminal")
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
            TextField("Name, for example Build", text: $newName)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
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
    /// They were capsules the height of a caption — small enough that switching between two
    /// shells was a target you had to aim at, and with the close action hidden in a context menu
    /// nothing on screen said a terminal could be closed at all. A browser's tabs are the shape
    /// that already means "these are open, one of them is in front, and each can be closed":
    /// wider than the name needs, as tall as a control rather than as tall as its text, the one
    /// you are in drawn in the surface rather than beside it, and a cross on each.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.terminals) { terminal in
                    tab(terminal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.04))
    }

    private func tab(_ terminal: RemoteTerminal) -> some View {
        let isSelected = model.selectedTerminalID == terminal.id
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(spacing: 8) {
            // Green while the shell is alive, grey once it has exited. The same vocabulary the
            // status pill uses for a streaming Mac, which is the point of putting it here.
            Circle()
                .fill(terminal.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)

            Text(terminal.name)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? ColorPalette.ink : .secondary)
                .lineLimit(1)

            if terminal.attention != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Button {
                model.closeTerminal(terminal.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    // A hit area rather than a glyph: an 11-point cross is not something a thumb
                    // can be asked to hit, and this one closes a shell.
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(terminal.name)")
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        // Tall enough to be a control, and wide enough that a one-word name is not a sliver.
        .frame(minWidth: 104, minHeight: 42)
        .background(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.05), in: shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
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
            // The keyboard has no dismiss key, so the panel provides one. Without it the field
            // takes focus on arrival and the keyboard stays for the life of the screen, over the
            // output the screen exists to show.
            Button {
                inputFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Hide the keyboard")
        }
        // Away from the edge. At 10 the field's text started close enough to the screen's edge
        // that the caret sat against it, which reads as clipped rather than as inset.
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
                terminalKey("esc", label: "Escape") { model.sendTerminalBytes([0x1B], to: id) }
                terminalKey("tab", label: "Tab") { model.sendTerminalBytes([0x09], to: id) }
                terminalKey("⌃C", label: "Interrupt") { model.sendTerminalBytes([0x03], to: id) }
                terminalKey("⌃D", label: "End of input") { model.sendTerminalBytes([0x04], to: id) }
                terminalKey("↑", label: "Up") { model.sendTerminalBytes(Array("\u{1B}[A".utf8), to: id) }
                terminalKey("↓", label: "Down") { model.sendTerminalBytes(Array("\u{1B}[B".utf8), to: id) }
                terminalKey("←", label: "Left") { model.sendTerminalBytes(Array("\u{1B}[D".utf8), to: id) }
                terminalKey("→", label: "Right") { model.sendTerminalBytes(Array("\u{1B}[C".utf8), to: id) }
                terminalKey("return", label: "Return") { model.sendTerminalBytes([0x0D], to: id) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.05))
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

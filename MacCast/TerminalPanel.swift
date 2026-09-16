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
                        // Says where the shell actually is. "Create a login shell" is the
                        // honest name for what the host starts, and it explains nothing to
                        // anyone who has not already used one — the question it left was
                        // whether this was a shell on the phone.
                        description: Text("A terminal runs on your Mac, not here — the same shell Terminal gives you, starting in your home folder. It keeps running when this phone disconnects.")
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
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func beginCreating() {
        if isCreating {
            isCreating = false
            newName = ""
            createFocused = false
            return
        }
        withAnimation(Motion.settle) { isCreating = true }
        // A turn later, because the field that wants focus is inserted by that animation — set
        // in the same pass there is nothing to focus yet and the keyboard never comes up.
        Task { @MainActor in createFocused = true }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // No name is a name: the host falls back to "Terminal N", which is a better answer than
        // refusing to start a shell over a label.
        model.createTerminal(name: name)
        newName = ""
        withAnimation(Motion.settle) { isCreating = false }
        createFocused = false
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.terminals) { terminal in
                    Button {
                        model.selectTerminal(terminal.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(terminal.isRunning ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(terminal.name).lineLimit(1)
                            if terminal.attention != nil {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            model.selectedTerminalID == terminal.id
                                ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close terminal", systemImage: "xmark", role: .destructive) {
                            model.closeTerminal(terminal.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(Color.white.opacity(0.04))
    }

    private func output(_ terminal: RemoteTerminal) -> some View {
        ScrollViewReader { reader in
            ScrollView([.vertical, .horizontal]) {
                Text(terminal.visibleOutput.isEmpty ? "Starting login shell…" : terminal.visibleOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(terminal.visibleOutput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                    .id("terminal-end")
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

    private func keyStrip(_ id: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                terminalKey("esc") { model.sendTerminalBytes([0x1B], to: id) }
                terminalKey("tab") { model.sendTerminalBytes([0x09], to: id) }
                terminalKey("⌃C") { model.sendTerminalBytes([0x03], to: id) }
                terminalKey("⌃D") { model.sendTerminalBytes([0x04], to: id) }
                terminalKey("↑") { model.sendTerminalBytes(Array("\u{1B}[A".utf8), to: id) }
                terminalKey("↓") { model.sendTerminalBytes(Array("\u{1B}[B".utf8), to: id) }
                terminalKey("←") { model.sendTerminalBytes(Array("\u{1B}[D".utf8), to: id) }
                terminalKey("→") { model.sendTerminalBytes(Array("\u{1B}[C".utf8), to: id) }
                terminalKey("return") { model.sendTerminalBytes([0x0D], to: id) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color.white.opacity(0.05))
    }

    private func terminalKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.monospaced().weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func submit(to id: UUID) {
        guard !command.isEmpty else { return }
        model.sendTerminalInput(command, to: id)
        command = ""
        inputFocused = true
    }
}

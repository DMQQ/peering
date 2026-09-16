import RemoteCore
import SwiftUI

/// A deliberately small native terminal surface. The Mac owns the PTY and shell; this view only
/// displays its bounded byte history and sends exact input bytes over the authenticated session.
struct TerminalPanel: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var newName = ""
    @State private var showsCreate = false
    @FocusState private var inputFocused: Bool

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
                    keyStrip(terminal.id)
                    input(terminal)
                } else {
                    ContentUnavailableView(
                        "No terminals",
                        systemImage: "terminal",
                        description: Text("Create a login shell on your Mac. It keeps running if this phone disconnects.")
                    )
                }
            }
            .background(Color.black)
            .navigationTitle("Mac terminals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.refreshTerminals() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button { showsCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New terminal")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshTerminals() }
        .alert("New terminal", isPresented: $showsCreate) {
            TextField("Name, for example Build", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                model.createTerminal(name: newName)
                newName = ""
            }
        } message: {
            Text("Starts your Mac login shell in your home folder.")
        }
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
            .onChange(of: terminal.output.count) { _, _ in
                reader.scrollTo("terminal-end", anchor: .bottom)
            }
        }
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
        }
        .padding(10)
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

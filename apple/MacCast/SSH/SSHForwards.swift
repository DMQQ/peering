import SSHCore
import SwiftUI

/// The three fields run in the direction the tunnel runs: nearly every mistake is one of direction, as `ssh -L` and `ssh -R` differ only in which end listens.
struct SSHForwardEditor: View {
    let existing: [SSHPortForward]
    let editing: SSHPortForward?
    let onSave: (SSHPortForward) -> Void
    let onDelete: ((SSHPortForward) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var localPort: String
    @State private var remoteHost: String
    @State private var remotePort: String
    @State private var isEnabled: Bool
    @State private var failure: SSHPortForwardError?
    @State private var isTouched = false

    init(
        existing: [SSHPortForward],
        editing: SSHPortForward?,
        onSave: @escaping (SSHPortForward) -> Void,
        onDelete: ((SSHPortForward) -> Void)?
    ) {
        self.existing = existing
        self.editing = editing
        self.onSave = onSave
        self.onDelete = onDelete
        _label = State(initialValue: editing?.label ?? "")
        _localPort = State(initialValue: editing.map { String($0.localPort) } ?? "")
        _remoteHost = State(initialValue: editing?.remoteHost ?? "")
        _remotePort = State(initialValue: editing.map { String($0.remotePort) } ?? "")
        _isEnabled = State(initialValue: editing?.isEnabled ?? true)
    }

    private var reading: Result<SSHPortForward, SSHPortForwardError> {
        SSHPortForward.reading(
            label: label,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            existing: existing,
            ignoring: editing?.id
        )
    }

    private var canSave: Bool {
        if case .success = reading { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Controls.card(
                        String(localized: "This iPhone"),
                        footer: String(localized: "The port another app on this phone will connect to. `localhost:\(localPort.isEmpty ? "8080" : localPort)` is what you point it at.")
                    ) {
                        VStack(spacing: 10) {
                            field(String(localized: "Name"), systemImage: "tag", text: $label, hint: String(localized: "Optional"))
                            Controls.divider
                            field(String(localized: "Local port"), systemImage: "number", text: $localPort, hint: "8080")
                                .keyboardType(.numberPad)
                        }
                    }

                    Controls.card(
                        String(localized: "The server's side"),
                        footer: String(localized: "Where the server connects to, seen from the server. This can be `127.0.0.1` for a service that only listens on the server itself, or a name that resolves only from there.")
                    ) {
                        VStack(spacing: 10) {
                            field(String(localized: "Host"), systemImage: "network", text: $remoteHost, hint: "db.internal")
                            Controls.divider
                            field(String(localized: "Port"), systemImage: "number", text: $remotePort, hint: "5432")
                                .keyboardType(.numberPad)
                        }
                    }

                    Controls.card(String(localized: "When a shell opens"), footer: String(localized: "A forward runs for as long as the shell on this server does. There is no way to keep one running in the background on an iPhone, so this is a setting about a shell rather than a service.")) {
                        Controls.toggle(String(localized: "Start it with the shell"), systemImage: "play", isOn: $isEnabled)
                    }

                    if isTouched, case .failure(let problem) = reading {
                        Text(HostWireText.localized(problem.message))
                            .font(.caption)
                            .foregroundStyle(ColorPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let editing, let onDelete {
                        Button(role: .destructive) {
                            onDelete(editing)
                            dismiss()
                        } label: {
                            Label("Delete this forward", systemImage: "trash")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ColorPalette.danger)
                        .padding(.top, 4)
                    }
                }
                .padding(18)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle(editing == nil ? "New forward" : "Edit forward")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { dismiss() }, confirm: "Save", canConfirm: canSave) {
                if case .success(let forward) = reading {
                    onSave(forward)
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
        // Set from the first keystroke: a form red before anything is typed scolds the user for arriving.
        .onChange(of: localPort) { _, _ in isTouched = true }
        .onChange(of: remoteHost) { _, _ in isTouched = true }
        .onChange(of: remotePort) { _, _ in isTouched = true }
    }

    private func field(
        _ title: String,
        systemImage: String,
        text: Binding<String>,
        hint: String
    ) -> some View {
        Controls.row(title, systemImage: systemImage) {
            TextField(hint, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(ColorPalette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

/// The list lives on the server because a forward to an unsaved machine has no credentials; the shell's screen holds whether any is up.
struct SSHForwardsCard: View {
    @Binding var forwards: [SSHPortForward]

    @State private var isAdding = false
    @State private var editing: SSHPortForward?

    var body: some View {
        Controls.card(String(localized: "Port forwards"), footer: footer) {
            VStack(spacing: 10) {
                if forwards.isEmpty {
                    Text("None. This server opens no ports on this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(forwards) { forward in
                        row(forward)
                        if forward.id != forwards.last?.id { Controls.divider }
                    }
                }

                Controls.divider

                Button {
                    isAdding = true
                } label: {
                    Label("Add a forward", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorPalette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $isAdding) {
            SSHForwardEditor(existing: forwards, editing: nil) { forward in
                forwards.append(forward)
            } onDelete: { _ in }
        }
        .sheet(item: $editing) { forward in
            SSHForwardEditor(existing: forwards, editing: forward) { updated in
                if let index = forwards.firstIndex(where: { $0.id == updated.id }) {
                    forwards[index] = updated
                }
            } onDelete: { removed in
                forwards.removeAll { $0.id == removed.id }
            }
        }
    }

    private var footer: String {
        forwards.contains { $0.isEnabled }
            ? String(localized: "These open when a shell on this server does, and close when it ends. Each one listens on this iPhone only, so another app on the phone can reach a service the server can see.")
            : String(localized: "A list of tunnels to set up. Each one listens on this iPhone only, so another app on the phone can reach a service the server can see.")
    }

    private func row(_ forward: SSHPortForward) -> some View {
        HStack(spacing: 10) {
            Button {
                editing = forward
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(forward.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(forward.isEnabled ? ColorPalette.ink : .secondary)
                        .lineLimit(1)
                    Text(forward.detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The switch is here too: turning one off is common and a sheet would be a form for a boolean.
            Toggle("", isOn: Binding(
                get: { forward.isEnabled },
                set: { isOn in
                    guard let index = forwards.firstIndex(where: { $0.id == forward.id }) else { return }
                    forwards[index].isEnabled = isOn
                }
            ))
            .labelsHidden()
            .tint(ColorPalette.accent)
            .accessibilityLabel("Start \(forward.displayName) with the shell")
        }
    }
}

/// Reached from the terminal toolbar: this screen is about a connection.
/// The footer says tunnels do not survive leaving the app: iOS runs no background daemon for it.
struct SSHForwardsSheet: View {
    let host: SSHHost
    let model: SSHModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.displayName)
                            .font(.headline)
                        Text(host.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if host.forwards.isEmpty {
                        Text("This server has no forwards. Add one under the server's own settings, and it opens with the next shell.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Controls.card(String(localized: "Forwards"), footer: String(localized: "A forward runs while this shell does. Closing the shell, or leaving the app for long enough, ends it, and nothing here can run in the background.")) {
                            VStack(spacing: 10) {
                                ForEach(host.forwards) { forward in
                                    row(forward)
                                    if forward.id != host.forwards.last?.id { Controls.divider }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("Ports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ forward: SSHPortForward) -> some View {
        let state = model.forwardState(forward, on: host)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(forward.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                Text(forward.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // The state on its own line, since it answers the only question the user came with.
                Text(HostWireText.forwardSummary(state))
                    .font(.caption2)
                    .foregroundStyle(tint(state))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                Task {
                    if state.isRunning {
                        await model.stop(forward, on: host)
                    } else {
                        await model.start(forward, on: host)
                    }
                }
            } label: {
                Text(state.isRunning ? "Stop" : "Start")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(state.isRunning ? ColorPalette.danger : ColorPalette.accent)
                    .frame(minWidth: 52, minHeight: 32)
            }
            .buttonStyle(.plain)
            .disabled(state == .starting)
        }
    }

    private func tint(_ state: SSHForwardState) -> Color {
        switch state {
        case .stopped: return .secondary
        case .starting: return ColorPalette.caution
        case .running(let problem): return problem == nil ? .green : ColorPalette.caution
        case .failed: return ColorPalette.danger
        }
    }
}

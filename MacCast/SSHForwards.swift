import SSHCore
import SwiftUI

/// Adding or changing one forward.
///
/// One screen for both, the same way the host editor is, and for the same reason: a field added to
/// one and forgotten on the other is a setting that can be set once and cannot be changed.
///
/// The three fields are laid out in the direction the tunnel runs, and the footer says which end is
/// which in as many words. Nearly every mistake a user makes here is one of direction — writing the
/// *phone's* port in the second box, or the server's own address in the third — because `ssh -L`
/// and `ssh -R` are two spellings of "forward" that differ only in which end listens.
struct SSHForwardEditor: View {
    /// The forwards already on this server, so the local port can be checked against them.
    let existing: [SSHPortForward]
    /// The one being changed, or nil for a new one.
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
    /// Whether the user has typed into anything, so the form does not go red before they start.
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

    /// What the three fields currently read as, or the first thing wrong with them.
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
                            field("Name", systemImage: "tag", text: $label, hint: "Optional")
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
                            field("Port", systemImage: "number", text: $remotePort, hint: "5432")
                                .keyboardType(.numberPad)
                        }
                    }

                    Controls.card(String(localized: "When a shell opens"), footer: String(localized: "A forward runs for as long as the shell on this server does. There is no way to keep one running in the background on an iPhone, so this is a setting about a shell rather than a service.")) {
                        Controls.toggle(String(localized: "Start it with the shell"), systemImage: "play", isOn: $isEnabled)
                    }

                    if isTouched, case .failure(let problem) = reading {
                        Text(problem.message)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if case .success(let forward) = reading {
                            onSave(forward)
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        // Set from the first keystroke rather than from the first render: a new forward opens with
        // three empty boxes, and a form that is red before anything has been typed is a form that
        // is telling the user off for arriving.
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

/// The forwards a server carries, as a card in the host editor.
///
/// The list lives *here*, on the server, because that is what it is a property of: a forward to a
/// machine nobody has saved is a forward with no credentials to open it with. What lives on the
/// shell's screen is the other half — whether any of it is up — because that is only true while a
/// connection is.
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

            // The switch is here rather than only inside the editor, because turning one off is the
            // common thing to want and opening a sheet to do it would be a form for a boolean.
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

/// The tunnels a shell is carrying, and what each is doing.
///
/// Reached from the terminal screen's toolbar rather than from the Servers list, and that is the
/// same decision the forward itself makes: this screen is about a *connection*. A list of forwards
/// on a server that is not connected would be a list of things none of which are running.
///
/// The rule is stated in the footer in as many words. A user who expects a tunnel to survive them
/// leaving the app is a user who will find out otherwise at the worst moment, and there is no way
/// to make it survive: iOS runs no background daemon for an app like this one.
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
                // The state, on its own line and in the colour of what it means, because on this
                // screen the state is the answer to the only question the user came here with.
                Text(state.summary)
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

import SSHCore
import SwiftUI

/// What the editor collected that is not part of what a server *is*.
///
/// Kept apart from the host for the reason the password always was: none of these is a property of
/// a row in a list. A password and a passcode are secrets, they live in the Keychain rather than in
/// `UserDefaults` beside the hostname, and the screen that gathers them is not the one that decides
/// where they go.
struct SSHHostSecrets {
    var password: String?
    var rememberPassword: Bool
    /// A passcode chosen in this visit, or nil to leave whatever is stored alone.
    var passcode: String?
}

/// Adding or changing a server.
///
/// One screen for both, because the fields are the same and the only difference is that one of
/// them arrives full. A separate "edit" screen is where the two drift — a field added to the
/// add-sheet and forgotten on the edit-sheet is a setting that can be set once and never changed.
struct SSHHostEditor: View {
    /// The host being changed, or nil when this is a new one.
    let existing: SSHHost?
    /// Whether a passcode is already stored for it.
    ///
    /// Passed in rather than looked up, because the store that holds it is the model's and this
    /// screen is handed everything else it shows. What the editor needs to know is only whether
    /// "Set" or "Change" is the honest word for the button, and whether a server may be saved
    /// asking for a passcode that does not exist yet.
    let hasStoredPasscode: Bool
    let onSave: (SSHHost, SSHHostSecrets) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var lock: SSHHostLock
    @State private var chosenPasscode: String?
    @State private var isChoosingPasscode = false

    init(
        existing: SSHHost?,
        hasStoredPasscode: Bool,
        onSave: @escaping (SSHHost, SSHHostSecrets) -> Void
    ) {
        self.existing = existing
        self.hasStoredPasscode = hasStoredPasscode
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _hostname = State(initialValue: existing?.hostname ?? "")
        _port = State(initialValue: existing.map { String($0.port) } ?? "22")
        _username = State(initialValue: existing?.username ?? "")
        _lock = State(initialValue: existing?.lock ?? .off)
    }

    private var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    /// Whether this server has a passcode behind it, counting one chosen in this visit.
    private var hasPasscode: Bool {
        chosenPasscode != nil || hasStoredPasscode
    }

    private var canSave: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
            // A server asking for a passcode nobody has set is a server with no way in, so the
            // one state that must not be saveable is exactly this one.
            && (lock != .passcode || hasPasscode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // The port is spelled out in the footer because the field accepts one and the
                    // default is otherwise invisible — a box reached on 2222 that silently says 22
                    // is a connection that fails with nothing on screen to explain it.
                    Controls.card(
                        "Server",
                        footer: "Name is what the tab is called; leave it empty and the host is used. The port is 22 unless your server says otherwise."
                    ) {
                        VStack(spacing: 10) {
                            field("Name", systemImage: "tag", text: $name, hint: "Optional")
                            Controls.divider
                            field("Host", systemImage: "network", text: $hostname, hint: "box.example.com")
                            Controls.divider
                            field("Port", systemImage: "number", text: $port, hint: "22")
                                .keyboardType(.numberPad)
                            Controls.divider
                            field("User", systemImage: "person", text: $username, hint: "root")
                        }
                    }

                    Controls.card("Lock", footer: lockFooter) {
                        VStack(spacing: 10) {
                            Controls.picker("Ask for", systemImage: "lock", selection: $lock) {
                                Text("Nothing").tag(SSHHostLock.off)
                                Text("Passcode").tag(SSHHostLock.passcode)
                                // Offered only where it can be answered. On a device with no
                                // passcode and no biometry, `deviceOwnerAuthentication` cannot be
                                // evaluated, and a lock chosen there would be a server the user
                                // could never open again.
                                if DeviceAuthentication.canLockServers || lock == .biometrics {
                                    Text(DeviceAuthentication.biometryName).tag(SSHHostLock.biometrics)
                                }
                            }

                            if lock == .passcode {
                                Controls.divider
                                Controls.row("Passcode", systemImage: "circle.grid.3x3") {
                                    Button(hasPasscode ? "Change" : "Set") { isChoosingPasscode = true }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(ColorPalette.accent)
                                }
                            }
                        }
                    }

                    Controls.card(
                        "Password",
                        footer: "A remembered password is kept in this iPhone's keychain, readable only after the first unlock and never copied to another device."
                    ) {
                        VStack(spacing: 10) {
                            HStack(spacing: 11) {
                                Controls.icon("key")
                                // Not a `SecureField`'s dots with a reveal: what is being typed is
                                // a password for a server the user just named, and hiding it while
                                // they check it against the clipboard is worse than showing it on
                                // a screen only they can see.
                                TextField(existing == nil ? "Password" : "Leave empty to keep the saved one",
                                          text: $password)
                                    .textContentType(.password)
                            }
                            Controls.divider
                            Controls.toggle("Remember it", systemImage: "lock", isOn: $rememberPassword)
                        }
                    }

                    // The primary action as a filled button, not a word in the corner. A toolbar
                    // "Save" sits at the same weight as the "Cancel" beside it and reads as another
                    // way out of the screen; this is the one control here that is a colour, and the
                    // accent is the app's own word for "this one is the right one".
                    Button {
                        commit()
                    } label: {
                        Text(existing == nil ? "Add server" : "Save changes")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(ColorPalette.accent)
                    .foregroundStyle(.white)
                    .disabled(!canSave)
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle(existing == nil ? "New Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isChoosingPasscode) {
            SSHPasscodePicker { passcode in
                chosenPasscode = passcode
            }
        }
    }

    /// The sentence under the Lock card, which has to say something different for each of the three
    /// answers — a footer that reads the same for all of them is a sentence about none of them.
    private var lockFooter: String {
        switch lock {
        case .off:
            return "A tap on this server opens a shell straight away."
        case .passcode:
            return "Six digits, kept in this iPhone's keychain. Setting the lock back to Nothing forgets it."
        case .biometrics:
            return "\(DeviceAuthentication.biometryName) asks for you before the shell opens. The device passcode is accepted as a fallback, so re-enrolling your face cannot shut you out of your own server."
        }
    }

    /// One labelled row. The hint is a placeholder rather than a value, so an untouched field is
    /// visibly empty rather than looking filled in with something the user did not choose.
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
                // A hostname is a hostname. iOS helpfully capitalising the first letter of
                // `box.example.com` produces a name that resolves to nothing, and the failure is
                // a connection refused rather than anything pointing at the field.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
    }

    private func commit() {
        guard let portNumber, canSave else { return }

        var host = existing ?? SSHHost(hostname: hostname, username: username)
        host.name = name.trimmingCharacters(in: .whitespaces)
        host.hostname = hostname.trimmingCharacters(in: .whitespaces)
        host.port = portNumber
        host.username = username.trimmingCharacters(in: .whitespaces)
        host.lock = lock

        onSave(host, SSHHostSecrets(
            password: password.isEmpty ? nil : password,
            rememberPassword: rememberPassword,
            // Only handed over for a server that is going to use one. A passcode chosen and then
            // left behind by a switch back to Nothing must not be stored on the way out — and the
            // model's own rule would drop it anyway, which is the point of having the rule there.
            passcode: lock == .passcode ? chosenPasscode : nil
        ))
        dismiss()
    }
}

/// Choosing the passcode for a locked server: six digits, then the same six again.
///
/// Twice, because this is the one passcode in the app typed from memory rather than read off a
/// screen — the pad shows dots, so a slip of the thumb is invisible here and would not surface
/// until the next connection, which is the worst moment there is to find out.
private struct SSHPasscodePicker: View {
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entered = ""
    /// The first entry, held while the second is typed.
    @State private var chosen: String?
    @State private var isMismatch = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(chosen == nil ? "Choose a passcode" : "Type it again")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                PasscodeDots(
                    filled: entered.count,
                    total: SSHPasscodeStore.length,
                    isRejected: isMismatch
                )

                Text(message)
                    .font(.caption)
                    .foregroundStyle(isMismatch ? ColorPalette.danger : .secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)

                PasscodePad(
                    onDigit: { digit in
                        guard entered.count < SSHPasscodeStore.length else { return }
                        entered.append(String(digit))
                        if entered.count == SSHPasscodeStore.length { advance() }
                    },
                    onDelete: {
                        guard !entered.isEmpty else { return }
                        entered.removeLast()
                    }
                )

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            .navigationTitle("Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(460)])
    }

    private var message: String {
        if isMismatch { return "Those two did not match. Start again." }
        return chosen == nil
            ? "You will be asked for this before this server opens."
            : "Once more, to be sure of it."
    }

    private func advance() {
        guard let chosen else {
            isMismatch = false
            self.chosen = entered
            entered = ""
            return
        }
        guard entered == chosen else {
            // Back to the start rather than to the confirmation: after a mismatch there is no
            // longer a entry worth confirming, and only the user knows which of the two was the
            // slip.
            self.chosen = nil
            entered = ""
            isMismatch = true
            return
        }
        onChoose(entered)
        dismiss()
    }
}

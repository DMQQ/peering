import SSHCore
import SwiftUI

struct SSHHostSecrets {
    /// One field rather than a password and a key, as in ``SSHCredential``: two optional fields could hand over both.
    var credential: SSHSecretChange
    /// Meaningless for a key, which is always kept.
    var rememberPassword: Bool
    var passcode: String?
}

/// Three cases, not an `SSHCredential?`: an optional cannot tell "changed nothing" from "took the key away". One must not write the keychain (a write per port edit can lose a key replaced meanwhile), the other must remove the entry.
enum SSHSecretChange {
    case unchanged
    case use(SSHCredential)
    case forget
}

/// One screen for add and edit: separate screens drift.
struct SSHHostEditor: View {
    /// Two cases rather than a `usesKey: Bool`, so a third way in is a case the compiler finds every use of.
    enum Method: Hashable { case password, key }

    let existing: SSHHost?
    /// Passed in because the store is the model's; the editor only needs to word the button and know whether a server may ask for a passcode not yet set.
    let hasStoredPasscode: Bool
    let onSave: (SSHHost, SSHHostSecrets) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var method: Method
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var key: SSHKeyPair?
    /// A key already there and left alone is not re-saved: a keychain write per port edit could drop a key replaced elsewhere.
    @State private var keyIsNew = false
    @State private var isChoosingKey = false
    @State private var hasCopiedKey = false
    @State private var lock: SSHHostLock
    @State private var forwards: [SSHPortForward]
    @State private var chosenPasscode: String?
    @State private var isChoosingPasscode = false

    init(
        existing: SSHHost?,
        credential: SSHCredential?,
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
        _forwards = State(initialValue: existing?.forwards ?? [])
        // A host with a key opens on the key half, so "why is this not asking for a password" is visible without a tap.
        if case .key(let stored) = credential {
            _method = State(initialValue: .key)
            _key = State(initialValue: stored)
        } else {
            _method = State(initialValue: .password)
        }
    }

    private var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    private var hasPasscode: Bool {
        chosenPasscode != nil || hasStoredPasscode
    }

    private var canSave: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
            // A server asking for a passcode nobody has set has no way in, so it must not be saveable.
            && (lock != .passcode || hasPasscode)
            // Same for the key half; a password needs no check, as an empty box means "ask next time".
            // The way out of the rule: a key taken away this visit is a working state too, else Remove would leave Save silently dead.
            && (method != .key || key != nil || keyIsNew)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // The port is spelled out because the default is otherwise invisible: a box reached on 2222 that silently says 22 fails with nothing to explain it.
                    Controls.card(String(localized: "Server"),
                        footer: String(localized: "Name is what the tab is called; leave it empty and the host is used. The port is 22 unless your server says otherwise.")
                    ) {
                        VStack(spacing: 10) {
                            field(String(localized: "Name"), systemImage: "tag", text: $name, hint: String(localized: "Optional"))
                            Controls.divider
                            field(String(localized: "Host"), systemImage: "network", text: $hostname, hint: "box.example.com")
                            Controls.divider
                            field(String(localized: "Port"), systemImage: "number", text: $port, hint: "22")
                                .keyboardType(.numberPad)
                            Controls.divider
                            field(String(localized: "User"), systemImage: "person", text: $username, hint: "root")
                        }
                    }

                    Controls.card(String(localized: "Lock"), footer: lockFooter) {
                        VStack(spacing: 10) {
                            Controls.picker(String(localized: "Ask for"), systemImage: "lock", selection: $lock) {
                                Text("Nothing").tag(SSHHostLock.off)
                                Text("Passcode").tag(SSHHostLock.passcode)
                                // Offered only where it can be answered: without a passcode or biometry `deviceOwnerAuthentication` cannot be evaluated and the server could never be opened.
                                if DeviceAuthentication.canLockServers || lock == .biometrics {
                                    Text(DeviceAuthentication.biometryName).tag(SSHHostLock.biometrics)
                                }
                            }

                            if lock == .passcode {
                                Controls.divider
                                Controls.row(String(localized: "Passcode"), systemImage: "circle.grid.3x3") {
                                    Button(hasPasscode ? "Change" : "Set") { isChoosingPasscode = true }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(ColorPalette.accent)
                                }
                            }
                        }
                    }

                    Controls.card(String(localized: "Sign in with"), footer: signInFooter) {
                        VStack(spacing: 10) {
                            Controls.picker(String(localized: "Using"), systemImage: "person.badge.key", selection: $method) {
                                Text("Password").tag(Method.password)
                                Text("Key").tag(Method.key)
                            }

                            switch method {
                            case .password:
                                Controls.divider
                                HStack(spacing: 11) {
                                    Controls.icon("key")
                                    // Shown rather than dotted: hiding a password the user is checking against the clipboard is worse.
                                    TextField(existing == nil ? "Password" : "Leave empty to keep the saved one",
                                              text: $password)
                                        .textContentType(.password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                Controls.divider
                                Controls.toggle(String(localized: "Remember it"), systemImage: "lock", isOn: $rememberPassword)

                            case .key:
                                Controls.divider
                                keySection
                            }
                        }
                    }

                    SSHForwardsCard(forwards: $forwards)

                    // A filled button, not a toolbar "Save": that sits at the weight of "Cancel" and reads as another way out.
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
            .sheetToolbar(onCancel: { dismiss() }, confirm: "Save", canConfirm: canSave) { commit() }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isChoosingPasscode) {
            SSHPasscodePicker { passcode in
                chosenPasscode = passcode
            }
        }
        .sheet(isPresented: $isChoosingKey) {
            SSHKeyImportSheet(existing: key, defaultLabel: keyLabel) { chosen in
                key = chosen
                keyIsNew = true
                // Cleared so switching back to Key does not show a stale "Copied" tick.
                hasCopiedKey = false
            }
        }
    }

    @ViewBuilder
    private var keySection: some View {
        if let key {
            SSHKeyCard(key: key, hasCopied: $hasCopiedKey)

            Controls.divider
            HStack(spacing: 18) {
                Button("Replace") { isChoosingKey = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ColorPalette.accent)
                Button("Remove", role: .destructive) {
                    // A removal is a change although its value is nil: the model reads a Key host with no key and `keyIsNew` as "forget what is stored", and the host does not record which method it uses, the credential does.
                    self.key = nil
                    keyIsNew = true
                }
                .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
        } else {
            Button {
                isChoosingKey = true
            } label: {
                Label("Add a key", systemImage: "key.horizontal")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ColorPalette.accent)
        }
    }

    /// The comment tells entries in `authorized_keys` apart; `user@host` is the convention.
    private var keyLabel: String {
        let user = username.trimmingCharacters(in: .whitespaces)
        let host = hostname.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !host.isEmpty else { return key?.comment ?? "" }
        return "\(user)@\(host)"
    }

    private var signInFooter: String {
        switch method {
        case .password:
            return String(localized: "A remembered password is kept in this iPhone's keychain, readable only after the first unlock and never copied to another device.")
        case .key where key == nil && keyIsNew:
            // The key-taken-away state says what it means for the next connection.
            return String(localized: "The key is forgotten when you save. Nothing on the server changes, and the next connection will ask for a password.")
        case .key:
            return String(localized: "A key replaces the password for this server, it does not sit beside one. The private half is kept in this iPhone's keychain; the public half is the line you put in `~/.ssh/authorized_keys` on the server.")
        }
    }

    private var lockFooter: String {
        switch lock {
        case .off:
            return String(localized: "A tap on this server opens a shell straight away.")
        case .passcode:
            return String(localized: "Six digits, kept in this iPhone's keychain. Setting the lock back to Nothing forgets it.")
        case .biometrics:
            return String(localized: "\(DeviceAuthentication.biometryName) asks for you before the shell opens. The device passcode is accepted as a fallback, so re-enrolling your face cannot shut you out of your own server.")
        }
    }

    /// The hint is a placeholder so an untouched field is visibly empty.
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
                // iOS capitalising `box.example.com` resolves to nothing, and the failure is a refused connection pointing at nothing.
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
        // Replaced whole rather than merged by id, as the card already did: a merge is a second rule about which list wins.
        host.forwards = forwards

        onSave(host, SSHHostSecrets(
            credential: credentialChange,
            rememberPassword: rememberPassword,
            // Only for a server that will use one: a passcode left by a switch back to Nothing must not be stored.
            passcode: lock == .passcode ? chosenPasscode : nil
        ))
        dismiss()
    }

    /// `.unchanged` is the common answer: editing a port must not rewrite the keychain, and an empty password box on a saved host means the saved one stands.
    private var credentialChange: SSHSecretChange {
        switch method {
        case .password:
            // An empty box means "keep what is saved"; forgetting is the row's own menu.
            return password.isEmpty ? .unchanged : .use(.password(password))
        case .key:
            guard keyIsNew else { return .unchanged }
            guard let key else { return .forget }
            return .use(.key(key))
        }
    }
}

/// Typed twice: this passcode is typed from memory and the pad shows dots, so a slip would surface at the next connection.
private struct SSHPasscodePicker: View {
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entered = ""
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
            .sheetToolbar(onCancel: { dismiss() })
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(460)])
    }

    private var message: String {
        if isMismatch { return String(localized: "Those two did not match. Start again.") }
        return chosen == nil
            ? String(localized: "You will be asked for this before this server opens.")
            : String(localized: "Once more, to be sure of it.")
    }

    private func advance() {
        guard let chosen else {
            isMismatch = false
            self.chosen = entered
            entered = ""
            return
        }
        guard entered == chosen else {
            // Back to the start: after a mismatch only the user knows which entry was the slip.
            self.chosen = nil
            entered = ""
            isMismatch = true
            return
        }
        onChoose(entered)
        dismiss()
    }
}

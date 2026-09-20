import SSHCore
import SwiftUI

/// What the editor collected that is not part of what a server *is*.
///
/// Kept apart from the host for the reason the password always was: none of these is a property of
/// a row in a list. A password, a key and a passcode are secrets, they live in the Keychain rather
/// than in `UserDefaults` beside the hostname, and the screen that gathers them is not the one that
/// decides where they go.
struct SSHHostSecrets {
    /// What to sign in with, or nil to leave whatever is stored alone.
    ///
    /// One field rather than a password and a key beside each other, which is the same decision
    /// ``SSHCredential`` makes and for a sharper reason here: two optional fields is a screen that
    /// can hand over both, and the model would then have to pick. Nothing in this type can express
    /// "a password and a key".
    var credential: SSHSecretChange
    /// Whether a password typed in this visit should be kept.
    ///
    /// Meaningless for a key, which is always kept: a private key that is not written down is a
    /// key the user has to import again on every connection, and nobody chooses that.
    var rememberPassword: Bool
    /// A passcode chosen in this visit, or nil to leave whatever is stored alone.
    var passcode: String?
}

/// What the editor decided about the secret a server signs in with.
///
/// Three cases rather than an `SSHCredential?`, and the third is the whole reason. An optional
/// cannot tell "the user changed nothing" from "the user took the key away", and those two want
/// opposite things done to the keychain: one must not write at all, because a write per edit of a
/// port number is a write that can lose a key something else replaced in the meantime, and the
/// other must remove the entry. A model that could not tell them apart would either wipe a key on
/// every edit or refuse to forget one ever.
enum SSHSecretChange {
    /// Nothing was touched. Whatever is stored stands.
    case unchanged
    /// This is what to sign in with from now on, replacing anything stored.
    case use(SSHCredential)
    /// The key was taken away, so the server holds nothing.
    case forget
}

/// Adding or changing a server.
///
/// One screen for both, because the fields are the same and the only difference is that one of
/// them arrives full. A separate "edit" screen is where the two drift — a field added to the
/// add-sheet and forgotten on the edit-sheet is a setting that can be set once and never changed.
struct SSHHostEditor: View {
    /// Which of the two ways in this server uses.
    ///
    /// Two cases rather than a `usesKey: Bool`, so the picker's tag and the switch over it are the
    /// same vocabulary, and so adding a third way in later is a case the compiler finds every use
    /// of rather than a second boolean nobody remembers to check.
    enum Method: Hashable { case password, key }

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
    @State private var method: Method
    @State private var password = ""
    @State private var rememberPassword = true
    /// The key this server uses: the stored one, or one chosen in this visit.
    @State private var key: SSHKeyPair?
    /// Whether that key arrived during this visit rather than being read out of the keychain.
    ///
    /// The difference decides what the screen hands back. A key that was already there and left
    /// alone is *not* re-saved — that would be a keychain write per edit of the port number, and a
    /// write that silently drops a key the user had just replaced elsewhere.
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
        // A host with a key opens on the key half of the card, which is the answer to "why is this
        // server not asking me for a password" being visible without a tap.
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
            // The same rule for the key half: a server set to sign in with a key and holding no
            // key is a server that cannot be opened, and it must not be possible to save one. A
            // password needs no such check — an empty box means "ask me next time", which is a
            // working state rather than a broken one.
            //
            // The second half of the test is the way out of the rule. A key that was *taken away*
            // in this visit is a server that will ask for a password next time, which is a working
            // state too; without it, Remove would leave the user on a screen whose Save button had
            // silently gone dead, with no clue which field was the problem.
            && (method != .key || key != nil || keyIsNew)
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

                    Controls.card("Sign in with", footer: signInFooter) {
                        VStack(spacing: 10) {
                            Controls.picker("Using", systemImage: "person.badge.key", selection: $method) {
                                Text("Password").tag(Method.password)
                                Text("Key").tag(Method.key)
                            }

                            switch method {
                            case .password:
                                Controls.divider
                                HStack(spacing: 11) {
                                    Controls.icon("key")
                                    // Not a `SecureField`'s dots with a reveal: what is being typed
                                    // is a password for a server the user just named, and hiding
                                    // it while they check it against the clipboard is worse than
                                    // showing it on a screen only they can see.
                                    TextField(existing == nil ? "Password" : "Leave empty to keep the saved one",
                                              text: $password)
                                        .textContentType(.password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                Controls.divider
                                Controls.toggle("Remember it", systemImage: "lock", isOn: $rememberPassword)

                            case .key:
                                Controls.divider
                                keySection
                            }
                        }
                    }

                    SSHForwardsCard(forwards: $forwards)

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
        .sheet(isPresented: $isChoosingKey) {
            SSHKeyImportSheet(existing: key, defaultLabel: keyLabel) { chosen in
                key = chosen
                keyIsNew = true
                // Cleared rather than left set, so switching back to Password and then to Key
                // again does not still be showing a "Copied" tick the user earned two screens ago.
                hasCopiedKey = false
            }
        }
    }

    /// The key half of the sign-in card: either the key and the way to get it onto the server, or
    /// the button that gets one.
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
                    // A removal is a change even though the value that replaces it is nil, and
                    // this is how the screen says so: the model reads a Key host with no key and
                    // `keyIsNew` set as "forget what is stored" rather than as "leave it alone".
                    // Without that flag there is no way to express the intention at all, because
                    // the *host* does not record which method it uses — the credential does.
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

    /// What a new key is named, following `ssh-keygen`'s own convention.
    ///
    /// The comment on a public key is what tells one entry in `authorized_keys` from another, and a
    /// line with no comment at all is a line the user cannot recognise a year later. `user@host` is
    /// the convention every other implementation uses, and this screen has both halves in hand.
    private var keyLabel: String {
        let user = username.trimmingCharacters(in: .whitespaces)
        let host = hostname.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !host.isEmpty else { return key?.comment ?? "" }
        return "\(user)@\(host)"
    }

    /// The sentence under the sign-in card, which says something different for each of the two
    /// answers — a footer that reads the same for both is a sentence about neither.
    private var signInFooter: String {
        switch method {
        case .password:
            return "A remembered password is kept in this iPhone's keychain, readable only after the first unlock and never copied to another device."
        case .key where key == nil && keyIsNew:
            // The one state where the key has been taken away, and the screen has to say what that
            // means for the next connection rather than leaving a blank space where a key was.
            return "The key is forgotten when you save. Nothing on the server changes, and the next connection will ask for a password."
        case .key:
            return "A key replaces the password for this server, it does not sit beside one. The private half is kept in this iPhone's keychain; the public half is the line you put in `~/.ssh/authorized_keys` on the server."
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
        // Replaced whole rather than merged by id, which is what the card's own add, edit and
        // delete already did to the array it was bound to. A merge here would be a second, subtler
        // rule about which of the two lists wins.
        host.forwards = forwards

        onSave(host, SSHHostSecrets(
            credential: credentialChange,
            rememberPassword: rememberPassword,
            // Only handed over for a server that is going to use one. A passcode chosen and then
            // left behind by a switch back to Nothing must not be stored on the way out — and the
            // model's own rule would drop it anyway, which is the point of having the rule there.
            passcode: lock == .passcode ? chosenPasscode : nil
        ))
        dismiss()
    }

    /// What, if anything, this visit changes about how the server is signed in to.
    ///
    /// `.unchanged` is the common answer: editing a port must not rewrite the keychain, and a
    /// password box left empty on a host that has one saved means the saved one stands. Only the
    /// cases where the user actually did something produce anything else, and the key half is
    /// guarded on the key having arrived in this visit for the same reason.
    private var credentialChange: SSHSecretChange {
        switch method {
        case .password:
            // An empty box is "keep what is saved", which is not the same as "forget it". The way
            // to forget a password is the row's own menu, where the words can say so.
            return password.isEmpty ? .unchanged : .use(.password(password))
        case .key:
            guard keyIsNew else { return .unchanged }
            guard let key else { return .forget }
            return .use(.key(key))
        }
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

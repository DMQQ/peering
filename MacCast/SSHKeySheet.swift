import SSHCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything a key needs a screen for, gathered in one file.
///
/// Three sheets and one card, because adding a key is three different arrivals — pasted, imported,
/// generated — and only the field labels differ between them. The part that does *not* differ, and
/// the reason these share a file, is what happens afterwards: whichever way the key arrived, the
/// user has to be able to read its public half and copy it, and that screen is the same one.

// MARK: - The key itself

/// What a saved key looks like in the editor: its type, its name, and the way to get it onto the
/// server.
///
/// The public half is shown *here*, inline, rather than behind a "Show public key" button, and that
/// is the single most important choice in the feature. A user who has just saved a key has one
/// thing left to do with it, and a screen that makes them find a second screen to do it is a screen
/// where the key quietly does not get installed and the next connection fails for a reason nothing
/// on the phone explains.
struct SSHKeyCard: View {
    let key: SSHKeyPair
    /// Whether a copy has just been made, so the button can say so.
    @Binding var hasCopied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Controls.row("Type", systemImage: "key.horizontal") {
                Text(Self.describe(key.algorithm))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Controls.row("Name", systemImage: "textformat") {
                Text(key.comment.isEmpty ? "None" : key.comment)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if key.passphrase != nil {
                Controls.divider
                Controls.row("Passphrase", systemImage: "lock") {
                    Text("Saved with it")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Controls.divider

            VStack(alignment: .leading, spacing: 8) {
                Text("Public key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Put this line in `~/.ssh/authorized_keys` on the server. It is the half that goes there; the private half never leaves this iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Selectable as well as copyable. Copying is the one-tap path, but a user pasting
                // into a terminal over this same connection has no clipboard to paste from, and a
                // line that can only be copied is a line they cannot read out.
                Text(key.publicKey)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ColorPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(ColorPalette.backdrop)
                    }

                Button {
                    UIPasteboard.general.string = key.publicKey
                    hasCopied = true
                } label: {
                    Label(hasCopied ? "Copied" : "Copy public key",
                          systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorPalette.accent)
            }
        }
    }

    /// The algorithm in the words a screen uses, rather than the protocol's.
    static func describe(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        default: return algorithm
        }
    }
}

// MARK: - Getting the public half out

/// The public half of a saved key, on its own, from the list.
///
/// Reached from the row's menu as well as from the editor, because the two are different errands.
/// The editor is where a key is set up; this is where a user comes back months later, at a server,
/// with something not working, to read the line out. It carries no private material and nothing
/// on it changes anything, which is why it is a screen rather than a sheet full of controls.
struct SSHPublicKeySheet: View {
    let host: SSHHost
    let key: SSHKeyPair

    @Environment(\.dismiss) private var dismiss
    @State private var hasCopied = false

    /// The label to install the key under.
    ///
    /// `ssh-keygen`'s own convention when the key arrived without one, which is the case for every
    /// key that came in encrypted: the comment sits behind the encryption and reading it would mean
    /// reimplementing aes-ctr here. A line with a `user@host` label is one the user can find again
    /// in `authorized_keys`; a line with nothing is one they have to guess at.
    private var label: String {
        key.comment.isEmpty ? "\(host.username)@\(host.hostname)" : key.comment
    }

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

                    Controls.card(
                        "Public key",
                        footer: "Append this line to `~/.ssh/authorized_keys` on the server. The private half stays in this iPhone's keychain and is never sent anywhere except as a signature."
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(key.labelled(label).publicKey)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(ColorPalette.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(ColorPalette.backdrop)
                                }

                            Button {
                                UIPasteboard.general.string = key.labelled(label).publicKey
                                hasCopied = true
                            } label: {
                                Label(hasCopied ? "Copied" : "Copy", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ColorPalette.accent)
                        }
                    }

                    Text("A one-line command that does it from the server's own shell:\n`echo '\(key.labelled(label).publicKey)' >> ~/.ssh/authorized_keys`")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("Public key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Where a key comes from

/// The three ways in, as one screen.
///
/// A segmented control rather than three separate buttons that each open a different sheet, because
/// the three answers produce the same thing and the user is choosing a *source*, not an action.
/// Having them side by side also makes the third one visible: a user who assumed they had to
/// already own a key finds out here that the app will make one.
struct SSHKeyImportSheet: View {
    let existing: SSHKeyPair?
    /// Handed the finished key. The caller stores it; this screen never touches the keychain.
    let onSave: (SSHKeyPair) -> Void

    /// Which of the three ways in is being used. Named rather than numbered, because "the second
    /// segment" is a sentence that stops being true the moment one is added.
    ///
    /// `.off` rather than `.none` for the third case's absence, which is the rule this app already
    /// follows: `Optional`'s `.none` is what `aSource == .none` would otherwise resolve to.
    private enum Source: Hashable { case paste, file, generate }

    @Environment(\.dismiss) private var dismiss

    @State private var source: Source = .paste
    @State private var pasted = ""
    @State private var passphrase = ""
    @State private var usesPassphrase = false
    @State private var label = ""
    @State private var isChoosingFile = false
    @State private var failure: String?
    /// The key that has been read but not yet saved, held so the label can be changed before it is.
    @State private var pending: SSHKeyPair?

    init(existing: SSHKeyPair?, defaultLabel: String, onSave: @escaping (SSHKeyPair) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _label = State(initialValue: defaultLabel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let pending {
                        Controls.card("Key", footer: "This is what will be saved. The name is only a label, and it is what the server's `authorized_keys` will show beside the key.") {
                            VStack(spacing: 10) {
                                SSHKeyCard(key: pending, hasCopied: .constant(false))
                                Controls.divider
                                field("Name", systemImage: "textformat", text: $label)
                            }
                        }
                    } else {
                        Controls.card("Where from", footer: sourceFooter) {
                            VStack(spacing: 10) {
                                Picker("Where from", selection: $source) {
                                    Text("Paste").tag(Source.paste)
                                    Text("File").tag(Source.file)
                                    Text("Generate").tag(Source.generate)
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: source) { _, _ in failure = nil }

                                switch source {
                                case .paste:
                                    Controls.divider
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Paste the private key, `-----BEGIN OPENSSH PRIVATE KEY-----` and all.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        TextEditor(text: $pasted)
                                            .font(.system(size: 12, design: .monospaced))
                                            .frame(height: 120)
                                            .scrollContentBackground(.hidden)
                                            .padding(8)
                                            .background {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(ColorPalette.backdrop)
                                            }
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                    }
                                case .file:
                                    Controls.divider
                                    Button {
                                        isChoosingFile = true
                                    } label: {
                                        Label("Choose a key file", systemImage: "folder")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(ColorPalette.accent)
                                case .generate:
                                    Controls.divider
                                    Text("A new Ed25519 key, made on this iPhone. Nothing to install and nothing to remember: the private half stays in this iPhone's keychain.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        if source != .generate {
                            Controls.card("Passphrase", footer: "Only if the key has one. It is kept in this iPhone's keychain beside the key, because a phone has no ssh-agent and a key that has to be unlocked by hand at every connection cannot be used at all.") {
                                VStack(spacing: 10) {
                                    Controls.toggle("It has a passphrase", systemImage: "lock", isOn: $usesPassphrase)
                                    if usesPassphrase {
                                        Controls.divider
                                        field("Passphrase", systemImage: "key", text: $passphrase, isSecret: true)
                                    }
                                }
                            }
                        }

                        Controls.card("Name", footer: "Only a label. It is what the server shows beside the key, and it is what tells your key apart from the one your laptop installed.") {
                            field("Name", systemImage: "textformat", text: $label)
                        }

                        if let failure {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(ColorPalette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle(existing == nil ? "Add a key" : "Replace the key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if pending == nil {
                        Button("Read key") { read() }.fontWeight(.semibold)
                    } else {
                        Button("Save") { commit() }.fontWeight(.semibold)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: label) { _, new in
            // Live, so the line the user is about to copy is the line they will see. Relabelling
            // after the fact would leave the screen showing one line and the clipboard holding
            // another, which is the sort of difference nobody notices until a server rejects a key.
            guard let key = pending else { return }
            pending = key.labelled(new)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.data, .text],
            allowsMultipleSelection: false
        ) { result in
            readFile(result)
        }
    }

    private var sourceFooter: String {
        switch source {
        case .paste:
            return "The private half, not the public one. If what you have starts with `ssh-ed25519`, that is the half the server wants."
        case .file:
            return "`.ssh/id_ed25519` on the machine you made the key on. AirDrop it across, or move it with the file browser."
        case .generate:
            return "For a server you have not set up a key for yet."
        }
    }

    private func field(_ title: String, systemImage: String, text: Binding<String>, isSecret: Bool = false) -> some View {
        Controls.row(title, systemImage: systemImage) {
            Group {
                if isSecret {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .multilineTextAlignment(.trailing)
            .foregroundStyle(ColorPalette.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
    }

    /// Reads whatever the chosen source offers, and either shows the parsed key or says why not.
    ///
    /// One method for all three sources, because the failure path is the part worth having once:
    /// every message a user sees when a key does not work comes from ``SSHKeyError``, and a second
    /// place that produced its own wording would be a second place to keep in step with the parser.
    private func read() {
        let phrase = usesPassphrase ? passphrase : nil
        do {
            switch source {
            case .generate:
                // Generated keys have no passphrase, so a label is the only thing to apply.
                pending = try SSHKeyPair.generate(comment: label).labelled(label)
            case .paste:
                pending = try SSHKeyPair.imported(pasted, passphrase: phrase).labelled(label)
            case .file:
                // The file has not been chosen yet; the picker's callback does the work.
                isChoosingFile = true
                return
            }
            failure = nil
        } catch let error as SSHKeyError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
    }

    private func readFile(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            // A file picked outside the app's container is not readable without this, and the
            // failure without it is a permission error that says nothing about the file.
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

            let text = try String(contentsOf: url, encoding: .utf8)
            pending = try SSHKeyPair.imported(text, passphrase: usesPassphrase ? passphrase : nil).labelled(label)
            failure = nil
        } catch let error as SSHKeyError {
            failure = error.message
        } catch {
            failure = "That file could not be read: \(error.localizedDescription)"
        }
    }

    private func commit() {
        guard let pending else { return }
        onSave(pending)
        dismiss()
    }
}

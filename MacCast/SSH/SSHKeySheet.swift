import SSHCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Three sheets and one card: adding a key is three arrivals that differ only in field labels. They share a file for what comes after: the user must be able to read the public half and copy it.

// MARK: - The key itself

/// The public half is shown inline, not behind a "Show public key" button: a key that is not installed because finding the second screen was a chore fails the next connection for a reason nothing on the phone explains.
struct SSHKeyCard: View {
    let key: SSHKeyPair
    @Binding var hasCopied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Controls.row(String(localized: "Type"), systemImage: "key.horizontal") {
                Text(Self.describe(key.algorithm))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Controls.row(String(localized: "Name"), systemImage: "textformat") {
                Text(key.comment.isEmpty ? String(localized: "None") : key.comment)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if key.passphrase != nil {
                Controls.divider
                Controls.row(String(localized: "Passphrase"), systemImage: "lock") {
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

                // Selectable as well as copyable: a user pasting into a terminal over this same connection has no clipboard to paste from.
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

    static func describe(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        default: return algorithm
        }
    }
}

// MARK: - Getting the public half out

/// Reached from the row's menu as well as the editor: this is where a user comes back months later, at a server, to read the line out. It carries no private material.
struct SSHPublicKeySheet: View {
    let host: SSHHost
    let key: SSHKeyPair

    @Environment(\.dismiss) private var dismiss
    @State private var hasCopied = false

    /// `ssh-keygen`'s own convention when the key arrived without a label, which is every encrypted key: the comment sits behind the encryption and reading it would mean reimplementing aes-ctr here.
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

                    Controls.card(String(localized: "Public key"),
                        footer: String(localized: "Append this line to `~/.ssh/authorized_keys` on the server. The private half stays in this iPhone's keychain and is never sent anywhere except as a signature.")
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

/// A segmented control rather than three buttons: the user is choosing a source, not an action, and side by side the third (generate) is visible.
struct SSHKeyImportSheet: View {
    let existing: SSHKeyPair?
    /// Handed the finished key. The caller stores it; this screen never touches the keychain.
    let onSave: (SSHKeyPair) -> Void

    /// Named rather than numbered: "the second segment" stops being true once one is added.
    /// `.off` rather than `.none`, since `aSource == .none` would resolve to `Optional`'s `.none`.
    private enum Source: Hashable { case paste, file, generate }

    @Environment(\.dismiss) private var dismiss

    @State private var source: Source = .paste
    @State private var pasted = ""
    @State private var passphrase = ""
    @State private var usesPassphrase = false
    @State private var label = ""
    @State private var isChoosingFile = false
    @State private var failure: String?
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
                        Controls.card(String(localized: "Key"), footer: String(localized: "This is what will be saved. The name is only a label, and it is what the server's `authorized_keys` will show beside the key.")) {
                            VStack(spacing: 10) {
                                SSHKeyCard(key: pending, hasCopied: .constant(false))
                                Controls.divider
                                field(String(localized: "Name"), systemImage: "textformat", text: $label)
                            }
                        }
                    } else {
                        Controls.card(String(localized: "Where from"), footer: sourceFooter) {
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
                            Controls.card(String(localized: "Passphrase"), footer: String(localized: "Only if the key has one. It is kept in this iPhone's keychain beside the key, because a phone has no ssh-agent and a key that has to be unlocked by hand at every connection cannot be used at all.")) {
                                VStack(spacing: 10) {
                                    Controls.toggle(String(localized: "It has a passphrase"), systemImage: "lock", isOn: $usesPassphrase)
                                    if usesPassphrase {
                                        Controls.divider
                                        field(String(localized: "Passphrase"), systemImage: "key", text: $passphrase, isSecret: true)
                                    }
                                }
                            }
                        }

                        Controls.card(String(localized: "Name"), footer: String(localized: "Only a label. It is what the server shows beside the key, and it is what tells your key apart from the one your laptop installed.")) {
                            field(String(localized: "Name"), systemImage: "textformat", text: $label)
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
            // Live, so the line the user is about to copy is the line they see: relabelling afterwards would leave the screen and the clipboard disagreeing until a server rejects the key.
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
            return String(localized: "The private half, not the public one. If what you have starts with `ssh-ed25519`, that is the half the server wants.")
        case .file:
            return String(localized: "`.ssh/id_ed25519` on the machine you made the key on. AirDrop it across, or move it with the file browser.")
        case .generate:
            return String(localized: "For a server you have not set up a key for yet.")
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

    /// One method for all three sources so every failure message comes from ``SSHKeyError``, one place to keep in step with the parser.
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
            // A file picked outside the app's container is not readable without this, and the failure is a permission error that says nothing about the file.
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

            let text = try String(contentsOf: url, encoding: .utf8)
            pending = try SSHKeyPair.imported(text, passphrase: usesPassphrase ? passphrase : nil).labelled(label)
            failure = nil
        } catch let error as SSHKeyError {
            failure = error.message
        } catch {
            failure = String(localized: "That file could not be read: \(error.localizedDescription)")
        }
    }

    private func commit() {
        guard let pending else { return }
        onSave(pending)
        dismiss()
    }
}

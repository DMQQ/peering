import SSHCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
            failure = HostWireText.localized(error.message)
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
            failure = HostWireText.localized(error.message)
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

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

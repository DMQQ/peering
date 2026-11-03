import PeeringKit
import SSHCore
import SwiftUI

extension SSHTab {
    // MARK: - Connecting

    /// Straight to open, bypassing the lock gate on purpose: the user is already signed in to this machine.
    func openAnother(_ host: SSHHost) {
        if let stored = model.storedCredential(for: host) {
            model.open(host, credential: stored, remember: false)
        } else {
            model.pendingPasswordHost = host
        }
    }

    func passwordSheet(for host: SSHHost) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.displayName)
                        .font(.headline)
                    Text(host.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                TextField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ColorPalette.surface)
                    }
                    .onSubmit { commitPassword(for: host) }

                Toggle("Remember it", isOn: $rememberPassword)
                    .tint(ColorPalette.accent)
                    .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            // Cleared here: three paths raise the question, and a password typed at the last must not wait at the next.
            .onAppear {
                password = ""
                rememberPassword = true
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(
                onCancel: { model.pendingPasswordHost = nil },
                confirm: "Connect",
                canConfirm: !password.isEmpty
            ) { commitPassword(for: host) }
        }
        .presentationDetents([.height(340)])
        .preferredColorScheme(.dark)
    }

    private func commitPassword(for host: SSHHost) {
        guard !password.isEmpty else { return }
        model.open(host, credential: .password(password), remember: rememberPassword)
        password = ""
        model.pendingPasswordHost = nil
    }

    // MARK: - The first-sight key

    func keyPromptSheet(_ prompt: SSHKeyPrompt) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Is this the right machine?")
                        .font(.headline)
                    Text("This is the first time you have connected to \(prompt.prompt.endpoint.display). Check its fingerprint against the server itself. Most providers show it in their console, and `ssh-keygen -lf` prints it on the box.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.prompt.algorithm)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt.prompt.fingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(ColorPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ColorPalette.surface)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            .navigationTitle("New server")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { model.answerKeyPrompt(false) }, confirm: "Trust") {
                model.answerKeyPrompt(true)
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.height(420)])
        .preferredColorScheme(.dark)
    }
}

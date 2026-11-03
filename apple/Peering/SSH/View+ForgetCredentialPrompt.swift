import PeeringKit
import SSHCore
import SwiftUI

/// An alert, see ``TerminalEndPrompt``. It destroys a key the user can only regenerate on the machine that made it.
extension View {
    func forgetCredentialPrompt(
        host: SSHHost?,
        isPresented: Binding<Bool>,
        onForget: @escaping () -> Void
    ) -> some View {
        alert("Forget how to sign in?", isPresented: isPresented) {
            // Cancel first and given the role, so Escape and a stray return land on keeping it.
            Button("Keep it", role: .cancel) { }
            Button("Forget", role: .destructive, action: onForget)
        } message: {
            Text("\(host?.displayName ?? String(localized: "This server")) will ask for a password the next time you open a shell. Nothing on the server itself is touched, and any key already in `authorized_keys` stays there.")
        }
    }
}

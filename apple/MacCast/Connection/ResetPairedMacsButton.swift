import SwiftUI

/// The way out of a pairing store whose saved data is damaged: shown only in that state, since a locked Keychain only needs unlocking.
struct ResetPairedMacsButton: View {
    let model: SessionModel
    @State private var confirming = false

    var body: some View {
        Button("Reset paired Macs", role: .destructive) { confirming = true }
            .alert("Reset paired Macs?", isPresented: $confirming) {
                Button("Reset", role: .destructive) { model.resetPairedMacs() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The pairings saved on this iPhone are damaged and cannot be recovered. Resetting deletes them, and you will pair each Mac again. Nothing on your Macs is changed.")
            }
    }
}

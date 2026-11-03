import SSHCore
import SwiftUI

/// Typed twice: this passcode is typed from memory and the pad shows dots, so a slip would surface at the next connection.
struct SSHPasscodePicker: View {
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

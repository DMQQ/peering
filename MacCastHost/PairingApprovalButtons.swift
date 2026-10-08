import SwiftUI

/// Shown once a phone has typed the digits by hand: unlike a scanned QR code, that proves nothing
/// to the Mac, so its user is the one who decides.
struct PairingApprovalButtons: View {
    let clientName: String
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(String(localized: "\(clientName) entered the code. Is that you?"))
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(String(localized: "Decline")) { resolve(false) }
                Button(String(localized: "Approve")) { resolve(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

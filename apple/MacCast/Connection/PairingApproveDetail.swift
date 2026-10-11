import SwiftUI

/// What the phone says once its half is done and the Mac's owner has the other: a typed code is still waiting on a click there, a scanned one is only being sealed.
struct PairingApproveDetail: View {
    let kind: PairingSubmission
    let hostName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .scanned
                 ? "Finishing a secure pairing with “\(hostName)”."
                 : "Click Approve on “\(hostName)”. It is asking whether you entered the code.")
                .stepDetail()
            ProgressView().tint(ColorPalette.ink)
        }
    }
}

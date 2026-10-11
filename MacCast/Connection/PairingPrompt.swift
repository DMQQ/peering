import RemoteCore
import SwiftUI

/// A Mac being paired by someone who has paired before: the same steps as ``FirstConnectionScreen``, from the code onward. An overlay rather than a sheet, so it cannot be dismissed by a swipe: the connection is waiting on this answer.
struct PairingPrompt: View {
    @Environment(SessionModel.self) private var model
    let code: String
    let hostName: String
    @State private var submitted: PairingSubmission?

    /// A column of words reads best narrow: on a Mac's full display width the steps would stretch into lines nobody follows.
    private static let contentWidth: CGFloat = 460

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Pair with “\(hostName)”")
                        .font(DisplayFont.display(30))
                        .tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                    steps
                }
                .padding(.horizontal, 22)
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button("Cancel pairing") { model.confirmPairing(accepted: false) }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.bottom, 8)
            }
        }
        .animation(Motion.settle, value: submitted == nil)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuideStepRow(number: 1, state: .done, title: String(localized: "Mac found")) {
                Text("Connected to “\(hostName)”. It is showing six digits.").stepDetail()
            }
            GuideStepRow(number: 2, state: submitted == nil ? .current : .done, title: String(localized: "Enter the code")) {
                if submitted == nil {
                    PairingCodeEntry(code: code, hostName: hostName, submitted: $submitted)
                } else {
                    Text("Code entered.").stepDetail()
                }
            }
            GuideStepRow(number: 3, state: submitted == nil ? .pending : .current, title: approveTitle) {
                if let submitted { PairingApproveDetail(kind: submitted, hostName: hostName) }
            }
            GuideStepRow(number: 4, state: .pending, title: String(localized: "Connected"), isLast: true) {
                Text("Peering opens as soon as the Mac approves.").stepDetail()
            }
        }
    }

    private var approveTitle: String {
        submitted == .scanned ? String(localized: "Securing the pairing") : String(localized: "Approve on your Mac")
    }
}

extension Text {
    func stepDetail() -> some View {
        font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

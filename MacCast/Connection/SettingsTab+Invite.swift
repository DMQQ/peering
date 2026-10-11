import MacCastKit
import RemoteCore
import SwiftUI

extension SettingsTab {
    var inviteSection: some View {
        Controls.card(
            String(localized: "Invite a friend"),
            footer: inviteFooter
        ) {
            if let referral = model.referral {
                Controls.row(String(localized: "Your code"), systemImage: "ticket") {
                    Text(ReferralCode.display(referral.code))
                        .font(.subheadline.monospaced().weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .textSelection(.enabled)
                }

                Controls.divider

                ShareLink(item: inviteMessage(for: referral.code)) {
                    Controls.row(String(localized: "Share your code"), systemImage: "square.and.arrow.up") {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.99))
                .simultaneousGesture(TapGesture().onEnded { Analytics.referralShared() })
            }

            if model.referral?.redeemed != true {
                if model.referral != nil { Controls.divider }
                Button { redeemDraft = ""; redeemFailure = nil; showsRedeemAlert = true } label: {
                    Controls.row(String(localized: "Enter a friend's code"), systemImage: "gift") {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.99))
            }

            if let redeemFailure {
                Text(redeemFailure)
                    .font(.caption)
                    .foregroundStyle(ColorPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refreshReferral() }
        .alert(String(localized: "Enter a friend's code"), isPresented: $showsRedeemAlert) {
            TextField(String(localized: "ABCD-EFGH"), text: $redeemDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Redeem")) {
                let typed = redeemDraft
                guard ReferralCode.isComplete(typed) else {
                    redeemFailure = ReferralRefusal.unknownCode.message
                    return
                }
                Task { redeemFailure = await model.redeemReferral(code: typed) }
            }
        } message: {
            Text("You both get \(bonusMinutes) extra minutes a day for \(bonusDays) days.")
        }
    }

    private var bonusMinutes: Int { Int((model.referral?.bonusSeconds ?? 0) > 0 ? model.referral!.bonusSeconds / 60 : 30) }
    private var bonusDays: Int { 7 }

    private var inviteFooter: String {
        guard let referral = model.referral else {
            return String(localized: "Send a friend your code. They get extra time away from your own network, and so do you.")
        }
        if let end = referral.bonusEndsAt, end > Date() {
            let minutes = Int(referral.bonusSeconds / 60)
            return String(localized: "+\(minutes) minutes a day until \(end.formatted(date: .abbreviated, time: .omitted)). \(referral.invitesEarned) of \(referral.invitesMax) invites used.")
        }
        return String(localized: "\(referral.invitesEarned) of \(referral.invitesMax) invites used. Your friend gets extra time, and so do you while you are on the free plan.")
    }

    private func inviteMessage(for code: String) -> String {
        String(localized: "Peering lets me use my Mac from my iPhone. Open Settings, then Invite a friend, and enter my code \(ReferralCode.display(code)) for extra time away from your own network: https://getpeering.app")
    }
}

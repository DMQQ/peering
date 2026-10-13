import PeeringKit
import RemoteCore
import SwiftUI
import os

private let referralLog = Logger(subsystem: "pl.dmq.peering", category: "referral")

extension SessionModel {
    /// Extra seconds in each daily window while a grant runs.
    var referralBonusSeconds: TimeInterval {
        guard let referral else { return 0 }
        return ReferralBonus.activeSeconds(bonusSeconds: referral.bonusSeconds, endsAt: referral.bonusEndsAt)
    }

    /// Quiet on failure: the card keeps whatever it last knew, and a relay that is down is not news here.
    func refreshReferral() async {
        guard let identity else { return }
        do {
            referral = try await RelaySignallingConnection.referralStatus(
                at: ProtocolInfo.relaySignallingURL,
                clientID: device.id,
                identity: identity
            )
        } catch {
            referralLog.notice("referral status unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Returns what to tell the person, or nil on success.
    func redeemReferral(code typed: String) async -> String? {
        guard let identity else { return ReferralRefusal.needsKeyProof.message }
        do {
            referral = try await RelaySignallingConnection.redeemReferral(
                at: ProtocolInfo.relaySignallingURL,
                clientID: device.id,
                code: ReferralCode.canonical(typed),
                identity: identity
            )
            Analytics.referralRedeemed(outcome: "redeemed")
            return nil
        } catch RelaySignallingError.refused(let code, _) {
            let refusal = ReferralRefusal(code: code)
            Analytics.referralRedeemed(outcome: "\(refusal)")
            return refusal.message
        } catch {
            Analytics.referralRedeemed(outcome: "\(ReferralRefusal.unavailable)")
            return ReferralRefusal.unavailable.message
        }
    }
}

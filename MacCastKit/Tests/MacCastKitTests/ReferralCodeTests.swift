import Foundation
import Testing

@testable import MacCastKit

@Suite("Referral codes")
struct ReferralCodeTests {
    @Test("a typed code is upper case with no separators")
    func canonicalForm() {
        #expect(ReferralCode.canonical(" abcd-efgh ") == "ABCDEFGH")
        #expect(ReferralCode.canonical("abcd efgh") == "ABCDEFGH")
    }

    @Test("a code is complete at eight characters, however it was typed")
    func completeness() {
        #expect(ReferralCode.isComplete("abcd-efgh"))
        #expect(!ReferralCode.isComplete("abcd-efg"))
        #expect(!ReferralCode.isComplete(""))
    }

    @Test("a code is shown in two groups of four")
    func display() {
        #expect(ReferralCode.display("abcdefgh") == "ABCD-EFGH")
        #expect(ReferralCode.display("abc") == "ABC")
    }

    @Test("every relay error code maps to a refusal")
    func refusals() {
        #expect(ReferralRefusal(code: "referralUnknownCode") == .unknownCode)
        #expect(ReferralRefusal(code: "referralOwnCode") == .ownCode)
        #expect(ReferralRefusal(code: "referralAlreadyRedeemed") == .alreadyRedeemed)
        #expect(ReferralRefusal(code: "proofStale") == .needsKeyProof)
        #expect(ReferralRefusal(code: "referralsBusy") == .busy)
        #expect(ReferralRefusal(code: "tooManyRequests") == .busy)
        #expect(ReferralRefusal(code: "anything else") == .unavailable)
    }

    @Test("a bonus counts until its grants end and not after")
    func bonusWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ReferralBonus.activeSeconds(bonusSeconds: 1800, endsAt: Date(timeIntervalSince1970: 2_000), now: now) == 1800)
        #expect(ReferralBonus.activeSeconds(bonusSeconds: 1800, endsAt: Date(timeIntervalSince1970: 500), now: now) == 0)
        #expect(ReferralBonus.activeSeconds(bonusSeconds: 1800, endsAt: nil, now: now) == 0)
    }
}

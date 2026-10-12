package pl.dmq.peering.wire

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReferralWireTest {
    @Test
    fun aTypedCodeIsReducedToEightUpperCaseCharacters() {
        assertEquals("ABCDEFGH", ReferralCode.canonical(" abcd-efgh "))
        assertTrue(ReferralCode.isComplete("abcd efgh"))
        assertFalse(ReferralCode.isComplete("abcd-efg"))
    }

    @Test
    fun aCodeIsShownInTwoGroupsOfFour() {
        assertEquals("ABCD-EFGH", ReferralCode.display("abcdefgh"))
        assertEquals("ABC", ReferralCode.display("abc"))
    }

    @Test
    fun theRelaysErrorCodesMapToRefusals() {
        assertEquals(ReferralRefusal.UnknownCode, ReferralRefusal.of("referralUnknownCode"))
        assertEquals(ReferralRefusal.OwnCode, ReferralRefusal.of("referralOwnCode"))
        assertEquals(ReferralRefusal.AlreadyRedeemed, ReferralRefusal.of("referralAlreadyRedeemed"))
        assertEquals(ReferralRefusal.NeedsKeyProof, ReferralRefusal.of("proofStale"))
        assertEquals(ReferralRefusal.Busy, ReferralRefusal.of("tooManyRequests"))
        assertEquals(ReferralRefusal.Unavailable, ReferralRefusal.of("anythingElse"))
    }

    @Test
    fun theRequestsAreCamelCaseWithSortedKeys() {
        assertEquals(
            """{"clientId":"c","proof":"ab","proofTime":5,"publicKey":"04","type":"referralStatus"}""",
            RelayClientMessage.ReferralStatus("c", "04", "ab", 5).toJson(),
        )
        assertEquals(
            """{"clientId":"c","code":"ABCDEFGH","proof":"ab","proofTime":5,"publicKey":"04","type":"redeemReferral"}""",
            RelayClientMessage.RedeemReferral("c", "ABCDEFGH", "04", "ab", 5).toJson(),
        )
    }

    @Test
    fun aReferralReplyWithARunningGrantIsParsed() {
        val reply = RelayServerMessage.parse(
            """{"type":"referral","code":"ABCDEFGH","bonusSeconds":1800,"bonusEndsAt":2000,"redeemed":true,"invitesEarned":2,"invitesMax":5}""",
        )

        val standing = (reply as RelayServerMessage.Referral).standing
        assertEquals(RelayReferral("ABCDEFGH", 1800, 2000, true, 2, 5), standing)
        assertEquals(1800L, standing.activeBonusSeconds(nowSeconds = 1999))
        assertEquals(0L, standing.activeBonusSeconds(nowSeconds = 2000))
    }

    @Test
    fun aReferralReplyWithNoGrantHasNoEndTime() {
        val absent = RelayServerMessage.parse(
            """{"type":"referral","code":"ABCDEFGH","bonusSeconds":0,"redeemed":false,"invitesEarned":0,"invitesMax":5}""",
        )
        val explicitNull = RelayServerMessage.parse(
            """{"type":"referral","code":"ABCDEFGH","bonusSeconds":0,"bonusEndsAt":null,"redeemed":false,"invitesEarned":0,"invitesMax":5}""",
        )

        assertNull((absent as RelayServerMessage.Referral).standing.bonusEndsAt)
        assertNull((explicitNull as RelayServerMessage.Referral).standing.bonusEndsAt)
    }

    @Test
    fun theProofsSignTheReferralPayloads() {
        val signed = mutableListOf<ByteArray>()
        val signer = object : ProofSigner {
            override fun publicKey() = byteArrayOf(4)

            override fun sign(message: ByteArray): ByteArray = byteArrayOf(9).also { signed += message }
        }

        makeReferralStatusProof(signer, "CLI", 100)
        makeRedeemReferralProof(signer, "CLI", "ABCDEFGH", 100)

        assertArrayEquals(referralStatusPayload("CLI", 100), signed[0])
        assertArrayEquals(redeemReferralPayload("CLI", "ABCDEFGH", 100), signed[1])
    }
}

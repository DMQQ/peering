package pl.dmq.peering.session.relay

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock
import pl.dmq.peering.session.testing.FakeIdentity
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.wire.ReferralRefusal
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayReferral
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.referralStatusPayload
import pl.dmq.peering.wire.toHex

class ReferralClientTest {
    private val signalling = FakeSignalling()
    private val identity = FakeIdentity()
    private val client = ReferralClient(signalling, identity, FakeClock(unixNow = 1_760_000_000))
    private val standing = RelayReferral("ABCDEFGH", 1800, null, false, 0, 5)

    @Test
    fun statusSendsASignedRequestAndReturnsTheStanding() = runTest {
        signalling.reply(RelayServerMessage.Pong)
        signalling.reply(RelayServerMessage.Referral(standing))

        assertEquals(standing, client.status())

        val sent = signalling.sent.single() as RelayClientMessage.ReferralStatus
        assertEquals(identity.clientId, sent.clientId)
        assertEquals(identity.publicKey.toHex(), sent.publicKey)
        assertEquals(referralStatusPayload(identity.clientId, 1_760_000_000).let(identity::sign).toHex(), sent.proof)
        assertEquals(1_760_000_000L, sent.proofTime)
    }

    @Test
    fun redeemSendsTheCodeInItsCanonicalFormAndReturnsTheNewStanding() = runTest {
        val redeemed = standing.copy(redeemed = true)
        signalling.reply(RelayServerMessage.Referral(redeemed))

        assertEquals(redeemed, client.redeem("abcd-efgh"))

        assertEquals("ABCDEFGH", (signalling.sent.single() as RelayClientMessage.RedeemReferral).code)
    }

    @Test
    fun aRefusalCarriesTheReasonTheRelayGave() = runTest {
        signalling.reply(RelayServerMessage.Error("referralOwnCode", "own"))

        try {
            client.redeem("ABCDEFGH")
            fail("expected a refusal")
        } catch (refused: ReferralRefused) {
            assertEquals(ReferralRefusal.OwnCode, refused.refusal)
        }
        assertTrue(signalling.sent.single() is RelayClientMessage.RedeemReferral)
    }
}

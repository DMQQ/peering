package pl.dmq.peering.session.relay

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.Token

class RelayConnectTest {
    private val signalling = FakeSignalling()
    private val relay = RelayConnect(signalling)
    private val controlToken = Token(ByteArray(16) { 1 })
    private val videoToken = Token(ByteArray(16) { 2 })

    private fun sessionReady() = RelayServerMessage.SessionReady(
        controlHost = "control.example",
        controlPort = 4431,
        videoHost = "video.example",
        videoPort = 4500,
        controlToken = controlToken,
        videoToken = videoToken,
    )

    @Test
    fun requestSessionSendsTheConnectWithTheEntitlementAndReturnsTheGrant() = runTest {
        signalling.reply(sessionReady())

        val session = relay.requestSession(
            hostId = "host-1",
            clientId = "client-1",
            entitlement = RelayEntitlement(plan = "paid", playPurchaseToken = "token", playProductId = "pro"),
        )

        val sent = signalling.sent.single() as RelayClientMessage.ConnectToHost
        assertEquals("host-1", sent.hostId)
        assertEquals("client-1", sent.clientId)
        assertEquals(20, sent.protocolVersion)
        assertEquals("paid", sent.plan)
        assertEquals("token", sent.playPurchaseToken)
        assertEquals("pro", sent.playProductId)
        assertEquals(PeerAddress("control.example", 4431), session.control)
        assertEquals(PeerAddress("video.example", 4500), session.video)
        assertEquals(16, session.videoTokenBytes.size)
        assertEquals(16, session.controlHandoff().token.size)
        assertEquals(PeerAddress("control.example", 4431), session.controlHandoff().address)
    }

    @Test
    fun repliesUnrelatedToTheSessionAreSkipped() = runTest {
        signalling.reply(RelayServerMessage.Pong)
        signalling.reply(RelayServerMessage.Registered(sessionTtlSeconds = 600))
        signalling.reply(RelayServerMessage.PeerAddress("203.0.113.5", 5000))
        signalling.reply(RelayServerMessage.Unknown("referral"))
        signalling.reply(sessionReady())

        relay.requestSession("host-1", "client-1")

        assertEquals(1, signalling.sent.size)
    }

    @Test
    fun quotaExceededMapsToQuotaExceeded() = runTest {
        signalling.reply(RelayServerMessage.Error("quotaExceeded", "no time left"))

        assertRejects<RelaySessionException.QuotaExceeded> { relay.requestSession("host-1", "client-1") }
    }

    @Test
    fun versionErrorMapsToVersionMismatch() = runTest {
        signalling.reply(RelayServerMessage.Error("version", "protocol differs"))

        assertRejects<RelaySessionException.VersionMismatch> { relay.requestSession("host-1", "client-1") }
    }

    @Test
    fun hostOfflineErrorNamesTheRequestedHost() = runTest {
        signalling.reply(RelayServerMessage.Error("hostOffline", "gone"))

        val error = assertRejects<RelaySessionException.HostOffline> { relay.requestSession("host-1", "client-1") }
        assertEquals("host-1", error.hostId)
    }

    @Test
    fun hostOfflineReplyNamesTheReportedDevice() = runTest {
        signalling.reply(RelayServerMessage.HostOffline("host-9"))

        val error = assertRejects<RelaySessionException.HostOffline> { relay.requestSession("host-1", "client-1") }
        assertEquals("host-9", error.hostId)
    }

    @Test
    fun otherErrorsAreRefusedWithTheirCodeAndMessage() = runTest {
        signalling.reply(RelayServerMessage.Error("deviceRefused", "claimed by another key"))

        val error = assertRejects<RelaySessionException.Refused> { relay.requestSession("host-1", "client-1") }
        assertEquals("deviceRefused", error.code)
        assertEquals("claimed by another key", error.detail)
    }

    @Test
    fun presenceReadsEachHostUntilAllAreAnswered() = runTest {
        signalling.reply(RelayServerMessage.HostPresence("host-1", online = true))
        signalling.reply(RelayServerMessage.Pong)
        signalling.reply(RelayServerMessage.HostPresence("host-2", online = false))

        val presence = relay.hostPresence(listOf("host-1", "host-2"))

        assertEquals(mapOf("host-1" to true, "host-2" to false), presence)
        val expected = listOf(RelayClientMessage.HostPresence("host-1"), RelayClientMessage.HostPresence("host-2"))
        assertEquals(expected, signalling.sent)
    }

    @Test
    fun presenceStopsAtAnErrorAndKeepsWhatItHad() = runTest {
        signalling.reply(RelayServerMessage.HostPresence("host-1", online = true))
        signalling.reply(RelayServerMessage.Error("protocol", "older relay"))

        assertEquals(mapOf("host-1" to true), relay.hostPresence(listOf("host-1", "host-2")))
    }

    @Test
    fun presenceWithNoHostsSendsNothing() = runTest {
        assertEquals(emptyMap<String, Boolean>(), relay.hostPresence(emptyList()))
        assertTrue(signalling.sent.isEmpty())
    }

    @Test
    fun discoverPeerRepeatsTheAskUntilTheAddressIsKnown() = runTest {
        signalling.reply(RelayServerMessage.Error("peerAddressUnknown", "not yet"))
        signalling.reply(RelayServerMessage.Error("peerAddressUnknown", "not yet"))
        signalling.reply(RelayServerMessage.PeerAddress("203.0.113.7", 6000))

        val address = relay.discoverPeer(ByteArray(16) { 2 })

        assertEquals(PeerAddress("203.0.113.7", 6000), address)
        assertEquals(3, signalling.sent.size)
    }

    @Test
    fun discoverPeerGivesUpAfterTheAttemptsAreSpent() = runTest {
        repeat(3) { signalling.reply(RelayServerMessage.Error("peerAddressUnknown", "not yet")) }

        assertNull(relay.discoverPeer(ByteArray(16) { 2 }, attempts = 3, intervalMs = 150))
        assertEquals(3, signalling.sent.size)
    }

    @Test
    fun discoverPeerRefusesOtherErrors() = runTest {
        signalling.reply(RelayServerMessage.Error("unauthorized", "no"))

        assertRejects<RelaySessionException.Refused> { relay.discoverPeer(ByteArray(16) { 2 }) }
    }

    private suspend inline fun <reified T : RelaySessionException> assertRejects(block: () -> Unit): T {
        try {
            block()
        } catch (error: RelaySessionException) {
            if (error is T) return error
            fail("expected ${T::class.simpleName} but got $error")
        }
        fail("expected ${T::class.simpleName}")
        throw IllegalStateException("unreachable")
    }
}

@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.ReceivedDatagram
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.VIDEO_TOKEN_SIZE
import pl.dmq.peering.wire.VideoDirection
import pl.dmq.peering.wire.VideoOpener
import pl.dmq.peering.wire.VideoSealer

/** A relayed session whose Mac answers from [PEER] directly, sealing its datagrams the way the Mac does. */
class DirectPathTest {
    @Test
    fun aRelayedSessionSendsSealedProbesToTheAddressTheRelayNamed() = runTest {
        val rig = relayRig()
        rig.signalling.grantSession()
        rig.signalling.reply(RelayServerMessage.PeerAddress(PEER.host, PEER.port))

        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        val probe = rig.datagrams.sent.first { it.first == PEER }.second
        val opened = VideoOpener(rig.mac.videoSecret, VideoDirection.ClientToHost).open(probe)
        assertEquals(MessageKind.DirectProbe, opened?.kind)
        assertEquals(SessionRecord.Path.RELAY, readyPath(rig))
    }

    @Test
    fun anAuthenticatedDatagramFromTheMacsAddressReportsTheDirectPath() = runTest {
        val rig = relayRig()
        rig.signalling.grantSession()
        rig.signalling.reply(RelayServerMessage.PeerAddress(PEER.host, PEER.port))
        rig.controller.connect()
        settle()

        rig.deliverFromMac(from = PEER)
        advanceTimeBy(300)
        runCurrent()

        assertEquals(SessionRecord.Path.DIRECT, readyPath(rig))
    }

    @Test
    fun aDatagramThatDoesNotAuthenticateLeavesThePathOnTheRelay() = runTest {
        val rig = relayRig()
        rig.signalling.grantSession()
        rig.signalling.reply(RelayServerMessage.PeerAddress(PEER.host, PEER.port))
        rig.controller.connect()
        settle()

        rig.datagrams.deliver(ReceivedDatagram(OTHER, ByteArray(64) { 9 }))
        advanceTimeBy(300)
        runCurrent()

        assertEquals(SessionRecord.Path.RELAY, readyPath(rig))
    }

    @Test
    fun aRelayWithNoAddressYetIsAskedAgainAndNothingIsSentToAPeer() = runTest {
        val rig = relayRig()
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(5_000)
        runCurrent()

        assertTrue(rig.signalling.sent.any { it is RelayClientMessage.RequestPeerAddress })
        assertTrue(rig.datagrams.sent.none { it.first == PEER || it.first == OTHER })
        assertEquals(SessionRecord.Path.RELAY, readyPath(rig))
    }

    /** The Mac's direct datagrams: sealed with the relay token, which comes off before a peer reads them. */
    private fun ControllerRig.deliverFromMac(from: PeerAddress) {
        val sealer = VideoSealer(mac.videoSecret, VideoDirection.HostToClient, ByteArray(VIDEO_TOKEN_SIZE) { 2 })
        for (sealed in sealer.seal(MessageKind.DirectProbe, ByteArray(0))) {
            datagrams.deliver(ReceivedDatagram(from, sealed.copyOfRange(VIDEO_TOKEN_SIZE, sealed.size)))
        }
    }

    private fun readyPath(rig: ControllerRig): SessionRecord.Path =
        (rig.controller.state.value.phase as SessionPhase.Ready).path

    private fun TestScope.relayRig(): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Relay(ScriptedPairingHost.HOST_ID),
    )

    private companion object {
        val PEER = PeerAddress("198.51.100.9", 40_000)
        val OTHER = PeerAddress("203.0.113.50", 41_000)
    }
}

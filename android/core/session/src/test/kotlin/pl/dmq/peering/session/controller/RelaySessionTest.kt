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
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.Token

class RelaySessionTest {
    @Test
    fun aRelayedConnectAsksForASessionDialsTheGrantedControlSocketAndReachesReady() = runTest {
        val rig = relayRig()
        grantSession(rig.signalling)

        rig.controller.connect()
        settle()

        val ready = rig.controller.state.value.phase as SessionPhase.Ready
        assertEquals(SessionRecord.Path.RELAY, ready.path)
        val relayed = rig.routes.single() as ControlRoute.Relayed
        assertEquals(PeerAddress("control.example", 4431), relayed.handoff.address)
        assertTrue(rig.signalling.sent.single() is RelayClientMessage.ConnectToHost)
        assertTrue(rig.mac.connections.single().phoneFrames.ofKind(MessageKind.VideoKeyRequest).isNotEmpty())
        assertEquals(PeerAddress("video.example", 4500), rig.datagrams.sent.single().first)
    }

    @Test
    fun aQuotaExceededReplyEndsTheSessionWithoutADialOrARetry() = runTest {
        val rig = relayRig()
        rig.signalling.reply(RelayServerMessage.Error("quotaExceeded", "free time used"))

        rig.controller.connect()
        settle()

        assertEquals(
            SessionPhase.Failed(SessionFailure.Quota, canRetry = false),
            rig.controller.state.value.phase,
        )
        assertTrue(rig.routes.isEmpty())
    }

    private fun TestScope.relayRig(): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Relay(ScriptedPairingHost.HOST_ID),
    )

    private fun grantSession(signalling: FakeSignalling) {
        signalling.reply(
            RelayServerMessage.SessionReady(
                controlHost = "control.example",
                controlPort = 4431,
                videoHost = "video.example",
                videoPort = 4500,
                controlToken = Token(ByteArray(Token.SIZE) { 1 }),
                videoToken = Token(ByteArray(Token.SIZE) { 2 }),
            ),
        )
    }

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}

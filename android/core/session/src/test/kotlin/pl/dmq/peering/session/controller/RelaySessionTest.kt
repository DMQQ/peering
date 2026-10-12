@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.relay.RelayEntitlement
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

class RelaySessionTest {
    @Test
    fun aRelayedConnectAsksForASessionDialsTheGrantedControlSocketAndReachesReady() = runTest {
        val rig = relayRig()
        rig.signalling.grantSession()

        rig.controller.connect()
        settle()

        val ready = rig.controller.state.value.phase as SessionPhase.Ready
        assertEquals(SessionRecord.Path.RELAY, ready.path)
        val relayed = rig.routes.single() as ControlRoute.Relayed
        assertEquals(PeerAddress("control.example", 4431), relayed.handoff.address)
        assertTrue(rig.signalling.sent.first() is RelayClientMessage.ConnectToHost)
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

    @Test
    fun aRelayedConnectPresentsTheActivePurchaseToTheRelay() = runTest {
        val rig = relayRig(RelayEntitlement(plan = "pro", playPurchaseToken = "token-1", playProductId = "pro.year"))
        rig.signalling.grantSession()

        rig.controller.connect()
        settle()

        val sent = rig.signalling.sent.first() as RelayClientMessage.ConnectToHost
        assertEquals("pro", sent.plan)
        assertEquals("token-1", sent.playPurchaseToken)
        assertEquals("pro.year", sent.playProductId)
    }

    private fun TestScope.relayRig(entitlement: RelayEntitlement = RelayEntitlement()): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Relay(ScriptedPairingHost.HOST_ID),
        entitlement = entitlement,
    )
}

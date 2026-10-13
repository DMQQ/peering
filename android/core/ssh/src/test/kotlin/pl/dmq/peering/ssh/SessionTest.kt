package pl.dmq.peering.ssh

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeSecretStore
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.hostkey.KnownHostsStore
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshPortForward
import pl.dmq.peering.ssh.session.ForwardStatus
import pl.dmq.peering.ssh.session.SshPhase
import pl.dmq.peering.ssh.session.SshSession
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest

@OptIn(ExperimentalCoroutinesApi::class)
class SessionTest {
    private val connection = FakeConnection()
    private val transport = FakeTransport(connection)
    private val events = mutableListOf<TerminalEvent>()
    private val gate = HostKeyGate(KnownHostsStore(FakeSecretStore()), { 0 }) { true }
    private val forwards = listOf(
        SshPortForward("on", localPort = 8080, remoteHost = "db", remotePort = 5432),
        SshPortForward("off", localPort = 8081, remoteHost = "db", remotePort = 5433, isEnabled = false),
    )

    private fun TestScope.session(host: SshHost = SshHost("a", hostname = "h", username = "u", forwards = forwards)) =
        SshSession(host, SshCredential.Password("pw"), transport, gate, this, UnconfinedTestDispatcher(testScheduler))
            .also { it.addListener { event -> events += event } }

    @Test
    fun connectingOpensAShellAndBringsUpOnlyTheEnabledForwards() = runTest {
        val session = session()
        assertEquals(SshPhase.Connecting, session.phase.value)
        session.connect()
        advanceUntilIdle()
        assertEquals(SshPhase.Live, session.phase.value)
        assertEquals(1, events.filterIsInstance<TerminalEvent.Created>().size)
        assertEquals(listOf(Triple(8080, "db", 5432)), connection.forwarded)
        assertEquals(ForwardStatus.Running, session.forwardStatus.value["on"])
        session.close()
    }

    @Test
    fun theRequestCarriesTheHostsEndpointAndCredential() = runTest {
        val session = session(SshHost("a", hostname = "h", port = 2200, username = "root"))
        session.connect()
        advanceUntilIdle()
        assertEquals("h:2200", transport.seen!!.endpoint.key)
        assertEquals("root", transport.seen!!.username)
        assertEquals(SshCredential.Password("pw"), transport.seen!!.credential)
        session.close()
    }

    @Test
    fun aRefusedSignInEndsTheSessionWithTheReason() = runTest {
        transport.failure = SshFailure.AuthenticationFailed("password")
        val session = session()
        session.connect()
        advanceUntilIdle()
        val ended = session.phase.value as SshPhase.Ended
        assertTrue(ended.failure is SshFailure.AuthenticationFailed)
    }

    @Test
    fun requestsMadeBeforeTheLinkIsUpAreSentOnceItIs() = runTest {
        val session = session()
        session.send(TerminalRequest.ListTerminals)
        assertTrue(events.isEmpty())
        session.connect()
        advanceUntilIdle()
        assertEquals(1, events.filterIsInstance<TerminalEvent.Snapshot>().size)
        session.close()
    }

    @Test
    fun closingEndsTheConnectionAndTheTunnelsAndRecordsNoFailure() = runTest {
        val session = session()
        session.connect()
        advanceUntilIdle()
        session.close()
        assertTrue(connection.closed)
        assertEquals(SshPhase.Ended(null), session.phase.value)
        assertEquals(ForwardStatus.Stopped, session.forwardStatus.value["on"])
    }

    @Test
    fun aDroppedConnectionEndsTheShellsAndTheSession() = runTest {
        val session = session()
        session.connect()
        advanceUntilIdle()
        connection.lose("Connection reset")
        val ended = session.phase.value as SshPhase.Ended
        assertEquals("Connection reset", (ended.failure as SshFailure.Transport).reason)
        assertEquals(1, events.filterIsInstance<TerminalEvent.Exited>().size)
    }

    @Test
    fun aTunnelThatCannotBindFailsAloneAndTheShellStaysUsable() = runTest {
        connection.forwardFailure = "Address already in use"
        val session = session()
        session.connect()
        advanceUntilIdle()
        assertEquals(SshPhase.Live, session.phase.value)
        assertEquals(ForwardStatus.Failed("Address already in use"), session.forwardStatus.value["on"])
        session.close()
    }

    @Test
    fun aTunnelCanBeStoppedAndStartedAgainWhileTheShellRuns() = runTest {
        val session = session()
        session.connect()
        advanceUntilIdle()
        session.stopForward("on")
        assertEquals(ForwardStatus.Stopped, session.forwardStatus.value["on"])
        session.startForward(forwards[1])
        assertEquals(ForwardStatus.Running, session.forwardStatus.value["off"])
        assertFalse(connection.closed)
        session.close()
    }
}

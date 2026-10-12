@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.controller.ControlConnector
import pl.dmq.peering.session.controller.DownloadWriter
import pl.dmq.peering.session.controller.SessionController
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.controller.SessionPorts
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.hosts.PersistedHostDirectory
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakeClock
import pl.dmq.peering.session.testing.FakeIdentity
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.testing.FixedRandom

class SessionHolderTest {
    private class Opening(val ports: SessionPorts) : SessionOpener {
        val downloads = SessionDownloads()

        override fun open(target: ConnectTarget, scope: CoroutineScope): ActiveSession =
            ActiveSession(target, SessionController(scope, target, ports, SessionHistory()), lane = null, downloads = downloads)
    }

    private val hanging = ControlConnector { awaitCancellation() }

    private fun ports() = SessionPorts(
        identity = FakeIdentity(),
        clientName = "Phone",
        pins = FakePinStore(emptyMap()),
        random = FixedRandom(1),
        clock = FakeClock(),
        control = hanging,
        discovery = object : Discovery {
            override fun hosts(): Flow<DiscoveredHost> = flow { awaitCancellation() }
        },
        sink = FakeVideoSink(),
        downloads = DownloadWriter { _, _ -> },
    )

    private fun TestScope.holder(opening: SessionOpener) = SessionHolder(
        opening,
        PersistedHostDirectory(
            object : KeyValueStore {
                private val values = mutableMapOf<String, String>()
                override fun read(key: String): String? = values[key]
                override fun write(key: String, value: String) { values[key] = value }
            },
        ),
        CoroutineScope(StandardTestDispatcher(testScheduler)),
    )

    @Test
    fun endingASessionEndsItsControllerAndClearsTheActiveSession() = runTest {
        val holder = holder(Opening(ports()))
        val session = holder.connect(ConnectTarget.Lan(PeerAddress("192.0.2.1", 51515), "h1"))
        runCurrent()
        assertTrue(session.controller.state.value.phase is SessionPhase.Connecting)

        holder.end()
        runCurrent()

        assertEquals(SessionPhase.Ended, session.controller.state.value.phase)
        assertNull(holder.active.value)
    }

    @Test
    fun aNewSessionCanBeStartedAfterTheUserEndedTheLast() = runTest {
        val holder = holder(Opening(ports()))
        holder.connect(ConnectTarget.Lan(PeerAddress("192.0.2.1", 51515), "h1"))
        runCurrent()
        holder.end()
        runCurrent()

        val again = holder.connect(ConnectTarget.Lan(PeerAddress("192.0.2.1", 51515), "h1"))
        runCurrent()

        assertTrue(again.controller.state.value.phase is SessionPhase.Connecting)
        assertEquals(again, holder.active.value)
        holder.end()
    }
}

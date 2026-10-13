package pl.dmq.peering.session.flows

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.CommandRejection
import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetVideoEnabled
import pl.dmq.peering.wire.WireJson

class SessionLifecycleTest {
    @Test
    fun startingASessionReachesReadyAndRecordsItAsOpen() = runTest {
        val session = startSession(videoPause = true)

        val record = session.history.records.single()
        assertEquals(HOST_ID, record.hostId)
        assertEquals("Studio", record.hostName)
        assertEquals(SessionRecord.Path.LAN, record.path)
        assertNull(record.endedAt)
    }

    @Test
    fun pausingThePictureSendsSetVideoEnabledWhenTheHostDeclaresIt() = runTest {
        val session = startSession(videoPause = true)

        val frame = session.commands.send(SetVideoEnabled(false))

        assertNotNull(frame)
        assertEquals(MessageKind.Command, frame?.kind)
        assertEquals(SetVideoEnabled(false).toJson(), frame?.payload?.decodeToString())
        assertTrue(session.commands.takeRejections().isEmpty())
    }

    @Test
    fun pausingThePictureIsNotSentToAHostThatDoesNotDeclareIt() = runTest {
        val session = startSession(videoPause = null)

        assertNull(session.commands.send(SetVideoEnabled(false)))
        assertEquals(
            listOf(CommandRejection("SetVideoEnabled", HostCapability.VideoPause)),
            session.commands.takeRejections(),
        )
    }

    @Test
    fun resumingTheDeclaredPictureSendsSetVideoEnabledTrue() = runTest {
        val session = startSession(videoPause = true)
        session.commands.send(SetVideoEnabled(false))

        val frame = session.commands.send(SetVideoEnabled(true))

        assertNotNull(frame)
        assertEquals(SetVideoEnabled(true).toJson(), frame?.payload?.decodeToString())
    }

    @Test
    fun stoppingWritesTheClosedRecordAndTheHistorySurvivesARoundTrip() = runTest {
        val session = startSession(videoPause = true)
        advanceTimeBy(60_000)

        assertTrue(session.history.end(session.recordId, session.epochMillis(), SessionRecord.EndReason.USER_ENDED))

        val record = session.history.records.single()
        assertEquals(session.startedAt + 60_000, record.endedAt)
        assertEquals(SessionRecord.EndReason.USER_ENDED, record.reason)
        assertEquals(session.history.records, SessionHistory.fromJson(session.history.toJson()).records)
    }

    private class StartedSession(
        val history: SessionHistory,
        val commands: SessionCommands,
        val recordId: Long,
        val startedAt: Long,
        private val scope: TestScope,
    ) {
        fun epochMillis(): Long = startedAt + scope.testScheduler.currentTime
    }

    /** Runs the handshake to Ready with a host that declares [videoPause], then starts the history record. */
    private fun TestScope.startSession(videoPause: Boolean?): StartedSession {
        val hello = ServerHello(
            serverID = HOST_ID,
            hostName = "Studio",
            protocolVersion = PROTOCOL_VERSION,
            alreadyPaired = true,
            supportsVideoPause = videoPause,
        )
        val machine = ClientStateMachine(
            ClientConfig(CLIENT_ID, "Phone", HOST_ID, HOST_KEY),
            FakePinStore(mapOf(HOST_ID to HOST_KEY)),
            FixedRandom(1),
        )
        machine.start()
        val ready = machine.onFrame(serverHelloFrame(hello)).filterIsInstance<ClientAction.Ready>().single()

        val startedAt = START_EPOCH_MILLIS + testScheduler.currentTime
        val history = SessionHistory()
        val recordId = history.begin(ready.hello.serverID, ready.hello.hostName, SessionRecord.Path.LAN, startedAt)
        return StartedSession(history, SessionCommands(ready.hello), recordId, startedAt, this)
    }

    private fun serverHelloFrame(hello: ServerHello): Frame = Frame(
        MessageKind.ServerHello,
        WireJson.encodeToString(ServerHello.serializer(), hello).toByteArray(Charsets.UTF_8),
    )

    private companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
        const val HOST_ID = "MAC-STUDIO-01"
        val HOST_KEY = ByteArray(65) { 0x7 }
        const val START_EPOCH_MILLIS = 1_760_000_000_000L
    }
}

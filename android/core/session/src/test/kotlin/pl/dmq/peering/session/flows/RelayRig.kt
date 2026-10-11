package pl.dmq.peering.session.flows

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestCoroutineScheduler
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientHandshakeState
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.ReceivedDatagram
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.session.relay.DirectPathProber
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.relay.RelaySession
import pl.dmq.peering.session.testing.FakeControlTransport
import pl.dmq.peering.session.testing.FakeDatagramTransport
import pl.dmq.peering.session.testing.FakeIdentity
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.session.video.LaneOutput
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FrameEncoder
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.Token
import pl.dmq.peering.wire.VIDEO_SECRET_SIZE
import pl.dmq.peering.wire.VIDEO_TOKEN_SIZE
import pl.dmq.peering.wire.VideoChunkEncoder
import pl.dmq.peering.wire.VideoDirection
import pl.dmq.peering.wire.VideoKeyGrant
import pl.dmq.peering.wire.VideoSealer
import pl.dmq.peering.wire.VideoTransportKind
import pl.dmq.peering.wire.VideoTransportRequest
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.toBase64

/**
 * A phone's relayed session against a scripted relay and a scripted Mac. The relay grants a session; the Mac answers
 * the control handshake, grants the video key, and receives whatever the test scripts onto either lane. Pumps move
 * bytes the way the platform glue would, so nothing here opens a socket.
 */
class RelayRig(
    private val scope: CoroutineScope,
    private val scheduler: TestCoroutineScheduler,
    private val sinkFor: (FakeVideoSink) -> VideoSink = { it },
) {
    val signalling = FakeSignalling()
    val control = FakeControlTransport(peerKey = ScriptedPairingHost.HOST_KEY)
    val datagrams = FakeDatagramTransport()
    val sink = FakeVideoSink()
    val prober = DirectPathProber()
    val clock = TestSchedulerClock(scheduler)
    val notes = mutableListOf<String>()

    /** Every frame the phone wrote on the control connection, in order. */
    val controlWritten = mutableListOf<Frame>()

    private val pins = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY))
    private val machine = ClientStateMachine(
        ClientConfig(CLIENT_ID, "Phone", ScriptedPairingHost.HOST_ID, ScriptedPairingHost.HOST_KEY),
        pins,
        FixedRandom(1),
    )
    private val pairingHost = ScriptedPairingHost(alreadyPaired = true)
    private val controlInbound = FrameDecoder()
    private val videoSecret = ByteArray(VIDEO_SECRET_SIZE) { 7 }

    lateinit var session: RelaySession
        private set

    lateinit var lanes: VideoLanes
        private set

    private lateinit var hostSealer: VideoSealer

    val relayAddress: PeerAddress get() = session.video

    val handshakeReady: Boolean get() = machine.state == ClientHandshakeState.Ready

    /** Asks the relay for a session, completes the control handshake, and requests the video key. */
    suspend fun connect() {
        signalling.reply(
            RelayServerMessage.SessionReady(
                controlHost = CONTROL_HOST,
                controlPort = CONTROL_PORT,
                videoHost = VIDEO_HOST,
                videoPort = VIDEO_PORT,
                controlToken = Token(ByteArray(Token.SIZE) { 1 }),
                videoToken = Token(ByteArray(Token.SIZE) { 2 }),
            ),
        )
        session = RelayConnect(signalling, FakeIdentity(CLIENT_ID), clock).requestSession(HOST_ID, CLIENT_ID)
        lanes = VideoLanes(sinkFor(sink), clock, session.video, session.videoTokenBytes)
        hostSealer = VideoSealer(videoSecret, VideoDirection.HostToClient, session.videoTokenBytes)
        attachPumps()
        for (action in machine.start()) {
            if (action is ClientAction.Send) writeControl(action.frame)
        }
        settle()
        perform(lanes.start())
        settle()
    }

    /** Sends one picture as sealed datagrams, the way the relay forwards them: its token stripped, from [from]. */
    fun sendDatagram(kind: MessageKind, payload: ByteArray, from: PeerAddress = relayAddress) {
        for (sealed in hostSealer.seal(kind, payload)) {
            datagrams.deliver(ReceivedDatagram(from, sealed.copyOfRange(VIDEO_TOKEN_SIZE, sealed.size)))
        }
    }

    /** Sends one picture chunked on the control connection. */
    fun sendControlPicture(kind: MessageKind, payload: ByteArray, frameId: Long) {
        VideoChunkEncoder.encode(kind, payload, frameId, CONTROL_CHUNK_SIZE).forEach(::sendControlFrame)
    }

    fun sendControlFrame(frame: Frame) {
        control.script(FrameEncoder.encode(frame.kind, frame.payload))
    }

    /** Lets the pumps and every task due at the current virtual time run. */
    fun settle() {
        scheduler.runCurrent()
    }

    fun transportRequests(): List<VideoTransportKind> = controlWritten
        .filter { it.kind == MessageKind.VideoTransport }
        .map { WireJson.decodeFromString(VideoTransportRequest.serializer(), it.payload.decodeToString()).transport }

    private fun attachPumps() {
        scope.launch {
            control.received.collect { bytes ->
                controlInbound.push(bytes)
                drainControl()
            }
        }
        scope.launch {
            datagrams.received.collect { datagram ->
                val outcome = lanes.onDatagram(datagram.bytes)
                perform(outcome.outputs)
                if (outcome.authenticated && datagram.source != relayAddress) {
                    prober.onAuthenticatedDatagram(datagram.source)
                }
            }
        }
        scope.launch {
            while (true) {
                delay(TICK_MILLIS)
                perform(lanes.tick(clock.monotonicSeconds()))
            }
        }
        scope.launch {
            while (true) {
                delay(PONG_MILLIS)
                sendControlFrame(Frame(MessageKind.Pong, ByteArray(0)))
            }
        }
    }

    private suspend fun drainControl() {
        while (true) {
            val frame = controlInbound.next() ?: return
            if (machine.state == ClientHandshakeState.Ready) {
                perform(lanes.onControlFrame(frame))
            } else {
                for (action in machine.onFrame(frame)) {
                    if (action is ClientAction.Send) writeControl(action.frame)
                }
            }
        }
    }

    private suspend fun perform(outputs: List<LaneOutput>) {
        for (output in outputs) {
            when (output) {
                is LaneOutput.SendControl -> writeControl(output.frame)
                is LaneOutput.SendDatagram -> datagrams.send(output.bytes, output.destination)
                is LaneOutput.Note -> notes += output.text
            }
        }
    }

    private suspend fun writeControl(frame: Frame) {
        controlWritten += frame
        control.send(FrameEncoder.encode(frame.kind, frame.payload))
        macAnswers(frame).forEach(::sendControlFrame)
    }

    private fun macAnswers(frame: Frame): List<Frame> = when (frame.kind) {
        MessageKind.VideoKeyRequest -> {
            val grant = VideoKeyGrant(videoSecret.toBase64())
            listOf(Frame(MessageKind.VideoKey, WireJson.encodeToString(VideoKeyGrant.serializer(), grant).toByteArray()))
        }
        else -> pairingHost.receive(FrameEncoder.encode(frame.kind, frame.payload))
    }

    private companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
        const val HOST_ID = ScriptedPairingHost.HOST_ID
        const val CONTROL_HOST = "control.example"
        const val CONTROL_PORT = 4431
        const val VIDEO_HOST = "video.example"
        const val VIDEO_PORT = 4500
        const val CONTROL_CHUNK_SIZE = 512
        const val TICK_MILLIS = 500L
        const val PONG_MILLIS = 1_000L
    }
}

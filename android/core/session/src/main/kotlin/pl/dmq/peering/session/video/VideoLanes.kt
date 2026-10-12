package pl.dmq.peering.session.video

import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.session.connection.PingLedger
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.ChunkException
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PingPayload
import pl.dmq.peering.wire.SealException
import pl.dmq.peering.wire.VIDEO_SECRET_SIZE
import pl.dmq.peering.wire.VideoChunkReassembler
import pl.dmq.peering.wire.VideoDirection
import pl.dmq.peering.wire.VideoFallbackPolicy
import pl.dmq.peering.wire.VideoKeyGrant
import pl.dmq.peering.wire.VideoOpener
import pl.dmq.peering.wire.VideoSealer
import pl.dmq.peering.wire.VideoTransportKind
import pl.dmq.peering.wire.VideoTransportRequest
import pl.dmq.peering.wire.WireJson

/**
 * The picture's two lanes for a relayed session. The datagram lane is sealed and arrives through [onDatagram]; the
 * control lane is chunked inside the control connection and arrives through [onControlFrame]. Each lane owns its
 * own reassembly, because the two number their chunks independently. Driven by calls and [tick] only: it never
 * touches a socket, so the owner performs the returned [LaneOutput]s.
 */
class VideoLanes(
    private val sink: VideoSink,
    private val clock: Clock,
    private val relay: PeerAddress,
    private val videoToken: ByteArray,
) {
    val delivery = VideoDeliveryRecord(readyAt = clock.monotonicSeconds())

    /** Datagrams that did not open under the key, or were malformed. */
    var failedDatagrams: Int = 0
        private set

    /** The round trip of the last lane ping answered on the datagram lane, or null before one was. */
    var pathLatencyMillis: Double? = null
        private set

    private val router = VideoPictureRouter(sink)
    private val policy = VideoFallbackPolicy()
    private val pings = PingLedger()
    private val controlChunks = VideoChunkReassembler()
    private var started = false
    private var opener: VideoOpener? = null
    private var sealer: VideoSealer? = null
    private var lastPictureAt: Double? = clock.monotonicSeconds()
    private var lastControlReplyAt: Double? = null
    private var lastBindAt = 0.0
    private var lastPingAt = 0.0
    private var reportedFailure = false

    /** The key request to send on the control connection. The lane opens when the grant arrives. */
    fun start(): List<LaneOutput> {
        if (started) return emptyList()
        started = true
        return listOf(
            LaneOutput.SendControl(Frame(MessageKind.VideoKeyRequest, ByteArray(0))),
            LaneOutput.Note("Remote session open; asking the computer to send the picture over the relay."),
        )
    }

    /**
     * Seals one message onto the datagram lane for any destination, such as a direct probe. It shares the lane's single
     * sealer, because a second one would reuse nonces.
     */
    fun seal(kind: MessageKind, payload: ByteArray): List<ByteArray> = sealer?.seal(kind, payload) ?: emptyList()

    /**
     * Opens one datagram the relay forwarded. [DatagramOutcome.authenticated] is true when the datagram was not
     * rejected, so a replayed one also reads as authenticated: the opener refuses it silently.
     */
    fun onDatagram(bytes: ByteArray): DatagramOutcome {
        val current = opener ?: return DatagramOutcome(authenticated = false, outputs = emptyList())
        return try {
            current.open(bytes)?.let(::onPrimaryFrame)
            DatagramOutcome(authenticated = true, outputs = emptyList())
        } catch (error: SealException) {
            DatagramOutcome(authenticated = false, outputs = rejectedDatagram())
        }
    }

    /**
     * Opens one datagram that came straight from the computer's own address. Such a datagram has no relay token, and a stranger's
     * noise is dropped without counting as a failed relayed datagram. Returns true when it authenticated.
     */
    fun onDirectDatagram(bytes: ByteArray): Boolean {
        val current = opener ?: return false
        return try {
            current.open(bytes)?.let(::onPrimaryFrame)
            true
        } catch (error: SealException) {
            false
        }
    }

    /** Handles one frame that arrived on the control connection. Only video kinds and pongs are read here. */
    fun onControlFrame(frame: Frame): List<LaneOutput> = when (frame.kind) {
        MessageKind.VideoKey -> onKeyGrant(frame)
        MessageKind.VideoChunk -> {
            reassembleControl(frame)?.let { deliverPicture(it, VideoTransportKind.CONTROL) }
            emptyList()
        }
        MessageKind.VideoConfig, MessageKind.VideoFrame -> {
            deliverPicture(frame, VideoTransportKind.CONTROL)
            emptyList()
        }
        MessageKind.Pong -> {
            lastControlReplyAt = clock.monotonicSeconds()
            emptyList()
        }
        else -> emptyList()
    }

    /** Runs the fallback rules and the lane's keepalives. Call it on a steady beat, such as every half second. */
    fun tick(now: Double): List<LaneOutput> {
        val outputs = fallbackOutputs(now).toMutableList()
        val lane = sealer ?: return outputs
        if (now - lastBindAt >= BIND_INTERVAL_SECONDS) {
            lastBindAt = now
            outputs += LaneOutput.SendDatagram(lane.bindDatagram(), relay)
        }
        if (now - lastPingAt >= PING_INTERVAL_SECONDS) {
            lastPingAt = now
            outputs += pingOutputs(now, lane)
        }
        return outputs
    }

    private fun onKeyGrant(frame: Frame): List<LaneOutput> {
        if (!started) return emptyList()
        val secret = HandshakeFrames.decode(frame, VideoKeyGrant.serializer())
            ?.let { grant -> HandshakeFrames.parsed { grant.secretBytes } }
            ?.takeIf { it.size == VIDEO_SECRET_SIZE }
            ?: return listOf(LaneOutput.Note("The computer sent a video key this build could not read."))

        opener = VideoOpener(secret, VideoDirection.HostToClient)
        val newSealer = VideoSealer(secret, VideoDirection.ClientToHost, videoToken)
        sealer = newSealer
        val now = clock.monotonicSeconds()
        lastBindAt = now
        lastPingAt = now
        return listOf(
            LaneOutput.SendDatagram(newSealer.bindDatagram(), relay),
            LaneOutput.Note("The computer's video key arrived; the picture can come over the datagram lane."),
        )
    }

    private fun onPrimaryFrame(frame: Frame) {
        when (frame.kind) {
            MessageKind.Pong -> notePathLatency(frame)
            MessageKind.DirectProbe -> Unit
            else -> deliverPicture(frame, VideoTransportKind.PRIMARY)
        }
    }

    private fun reassembleControl(frame: Frame): Frame? = try {
        controlChunks.ingest(frame)
    } catch (error: ChunkException) {
        null
    }

    private fun deliverPicture(frame: Frame, lane: VideoTransportKind) {
        if (!router.deliver(frame)) return
        val now = clock.monotonicSeconds()
        lastPictureAt = now
        delivery.notePicture(now)
        if (lane == VideoTransportKind.PRIMARY) policy.notePrimaryPicture()
    }

    private fun notePathLatency(frame: Frame) {
        val sequence = HandshakeFrames.decode(frame, PingPayload.serializer())?.sequence
        val ping = pings.answered(sequence) ?: return
        pathLatencyMillis = (clock.monotonicSeconds() - ping.sentAtSeconds) * MILLIS_PER_SECOND
    }

    private fun pingOutputs(now: Double, lane: VideoSealer): List<LaneOutput> {
        val ping = pings.record(now)
        val payload = WireJson.encodeToString(PingPayload.serializer(), PingPayload(ping.sequence))
            .toByteArray(Charsets.UTF_8)
        return lane.seal(MessageKind.Ping, payload).map { LaneOutput.SendDatagram(it, relay) }
    }

    private fun fallbackOutputs(now: Double): List<LaneOutput> {
        val target = when (policy.advance(now, lastPictureAt, lastControlReplyAt, applies = opener != null)) {
            VideoFallbackPolicy.Decision.NONE -> return emptyList()
            VideoFallbackPolicy.Decision.USE_CONTROL_CHANNEL -> VideoTransportKind.CONTROL
            VideoFallbackPolicy.Decision.USE_PRIMARY_TRANSPORT -> VideoTransportKind.PRIMARY
        }
        val changed = delivery.transport != target
        delivery.note(target)
        val request = VideoTransportRequest(target, reasonFor(target))
        val frame = HandshakeFrames.json(MessageKind.VideoTransport, VideoTransportRequest.serializer(), request)
        val outputs = mutableListOf<LaneOutput>(LaneOutput.SendControl(frame))
        if (changed) outputs += LaneOutput.Note(noteFor(target))
        return outputs
    }

    private fun rejectedDatagram(): List<LaneOutput> {
        failedDatagrams += 1
        if (reportedFailure) return emptyList()
        reportedFailure = true
        return listOf(LaneOutput.Note(UNREADABLE_DATAGRAMS_NOTE))
    }

    private fun reasonFor(target: VideoTransportKind): String = when (target) {
        VideoTransportKind.CONTROL -> CONTROL_REASON
        VideoTransportKind.PRIMARY -> PRIMARY_REASON
    }

    private fun noteFor(target: VideoTransportKind): String = when (target) {
        VideoTransportKind.CONTROL -> CONTROL_NOTE
        VideoTransportKind.PRIMARY -> PRIMARY_NOTE
    }

    private companion object {
        const val BIND_INTERVAL_SECONDS = 10.0
        const val PING_INTERVAL_SECONDS = 1.0
        const val MILLIS_PER_SECOND = 1000.0
        const val CONTROL_REASON = "no picture on the datagram lane while the control channel answers"
        const val PRIMARY_REASON = "video is arriving again on the transport it prefers"
        const val CONTROL_NOTE = "No video is arriving on the datagram lane. Asking the computer for the control channel."
        const val PRIMARY_NOTE = "Video is arriving again on the datagram lane."
        const val UNREADABLE_DATAGRAMS_NOTE =
            "Some of the computer's video datagrams could not be read; the picture may fall back to the control channel."
    }
}

package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.session.relay.DirectPathState
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.AutoQualityPolicy
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.SetStreamQuality
import pl.dmq.peering.wire.VideoTransportKind
import kotlin.math.roundToInt
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * A control connection whose handshake completed, and the session parts that run on it: pings and the watchdog, the
 * coalesced command writer, the video lanes and the frame router. [serve] runs them until the link ends.
 */
internal class ConnectedLink(
    val hello: ServerHello,
    val route: OpenedRoute,
    private val clock: Clock,
    private val writer: WriterLoop,
    private val frames: ReceiveChannel<Frame>,
    sink: VideoSink,
    onPicture: () -> Unit,
    selection: SourceSelection,
    agent: AgentChat?,
    files: FileBrowser?,
    relay: RelayConnect?,
    private val quality: QualityChoice,
    private val ceiling: QualityTier,
) {
    private val liveness = LivenessMonitor(clock)
    val commands = SessionCommands(hello)
    private val lanes = VideoLanes(
        PictureSink(sink) {
            pictureSeen = true
            onPicture()
        },
        clock,
        route.videoPeer,
        route.videoToken,
    )
    private val router = FrameRouter(liveness, commands, lanes, selection, agent, files)
    private var pictureSeen = false
    private var automatic: AutoQualityPolicy? = null
    private val direct: DirectPathRunner? = route.datagrams?.let { datagrams ->
        relay?.let { DirectPathRunner(lanes, datagrams, it, route.videoToken) }
    }

    /** The route the picture is on: [SessionRecord.Path.DIRECT] once the Mac's own address has authenticated. */
    val path: SessionRecord.Path
        get() = if (direct?.prober?.state is DirectPathState.Open) SessionRecord.Path.DIRECT else route.path

    /** The notice the host last set, or null when none stands. */
    var notice: String? = null
        private set

    val latencyMillis: Int? get() = liveness.smoothedLatencyMillis()?.roundToInt()

    fun pictureState(paused: Boolean): PictureState = when {
        paused -> PictureState.Paused
        lanes.delivery.transport == VideoTransportKind.CONTROL -> PictureState.Fallback
        !pictureSeen -> PictureState.Connecting
        else -> PictureState.Live
    }

    fun enqueue(frame: Frame) = writer.enqueue(frame)

    /** Starts the link's loops in this scope. [ended] completes with the reason the link stopped. */
    fun CoroutineScope.serve(ended: CompletableDeferred<LinkEnd>, onTick: () -> Unit) {
        applyQuality(quality, ceiling)
        launchLinkTask(ended) {
            if (route.path == SessionRecord.Path.RELAY) {
                for (event in lanes.start().asEvents()) applyEvent(event, ended)
            }
            for (frame in frames) {
                for (event in router.route(frame)) applyEvent(event, ended)
            }
        }
        route.datagrams?.let { datagrams ->
            launchLinkTask(ended) {
                datagrams.received.collect { datagram ->
                    if (datagram.source == route.videoPeer) {
                        val outcome = lanes.onDatagram(datagram.bytes)
                        for (event in outcome.outputs.asEvents()) applyEvent(event, ended)
                    } else {
                        direct?.onForeignDatagram(datagram.source, datagram.bytes)
                    }
                }
            }
        }
        direct?.let { runner ->
            launchLinkTask(ended) { every(PROBE_INTERVAL) { runner.tick(clock.monotonicSeconds()) } }
        }
        launchLinkTask(ended) { every(COMMAND_INTERVAL) { commands.drain().forEach(writer::enqueue) } }
        launchLinkTask(ended) { every(PING_INTERVAL) { writer.enqueue(liveness.nextPing()) } }
        launchLinkTask(ended) {
            every(LANE_INTERVAL) {
                for (event in lanes.tick(clock.monotonicSeconds()).asEvents()) applyEvent(event, ended)
                steerAutomatic()
                if (liveness.isSilent(clock.monotonicSeconds(), SILENCE_LIMIT_SECONDS)) ended.complete(LinkEnd.Lost)
                onTick()
            }
        }
    }

    /** Holds the rate the user chose, or starts the policy that moves it, capped at [ceiling]. */
    fun applyQuality(choice: QualityChoice, ceiling: QualityTier) {
        when (choice) {
            QualityChoice.Automatic -> {
                val policy = AutoQualityPolicy(route.path.qualityPath(), ceiling)
                automatic = policy
                commands.offer(SetStreamQuality(fps = 0, bitrateKbps = policy.tier.kbps))
            }
            is QualityChoice.Fixed -> {
                automatic = null
                commands.offer(SetStreamQuality(fps = 0, bitrateKbps = minOf(choice.tier, ceiling).kbps))
            }
        }
    }

    /** The policy reads latency only: the decoder's dropped-frame count is not carried to this layer. */
    private fun steerAutomatic() {
        val policy = automatic ?: return
        if (lanes.delivery.transport == VideoTransportKind.CONTROL) return
        val latency = liveness.smoothedLatencyMillis() ?: return
        val tier = policy.observe(latency, newDroppedFrames = 0) ?: return
        commands.offer(SetStreamQuality(fps = 0, bitrateKbps = tier.kbps))
    }

    private suspend fun applyEvent(event: SessionEvent, ended: CompletableDeferred<LinkEnd>) {
        when (event) {
            is SessionEvent.Send -> writer.enqueue(event.frame)
            is SessionEvent.Offer -> commands.offer(event.command)
            is SessionEvent.Datagram -> route.datagrams?.send(event.bytes, event.destination)
            is SessionEvent.Notice -> notice = event.message
            is SessionEvent.Finish -> ended.complete(event.end)
        }
    }

    private suspend fun every(interval: Duration, step: suspend () -> Unit) {
        while (true) {
            delay(interval)
            step()
        }
    }

    private companion object {
        fun SessionRecord.Path.qualityPath(): AutoQualityPolicy.Path = when (this) {
            SessionRecord.Path.LAN -> AutoQualityPolicy.Path.LAN
            SessionRecord.Path.RELAY -> AutoQualityPolicy.Path.RELAY
            SessionRecord.Path.DIRECT -> AutoQualityPolicy.Path.DIRECT
        }

        val COMMAND_INTERVAL = 16.milliseconds
        val PROBE_INTERVAL = 250.milliseconds
        val LANE_INTERVAL = 250.milliseconds
        val PING_INTERVAL = LivenessMonitor.PING_INTERVAL_SECONDS.seconds
        const val SILENCE_LIMIT_SECONDS = 3.0
    }
}

package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.coroutineScope
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.ServerHello
import kotlin.coroutines.coroutineContext

/** Holds one control connection at a time: opens the route, runs the handshake, serves the session and tears it all down. */
internal class LinkRunner(
    private val target: ConnectTarget,
    private val ports: SessionPorts,
    private val selection: SourceSelection,
    private val services: SessionServices,
    private val recorder: SessionRecorder,
    private val prompt: PairingPrompt,
    private val update: ((SessionUiState) -> SessionUiState) -> Unit,
    private val onPicture: () -> Unit,
    private val publish: (ConnectedLink) -> Unit,
) {
    /** The session being served, or null between links. */
    var link: ConnectedLink? = null
        private set

    /** Whether any link has become ready since [forgetReadiness]; an unreachable first dial fails, a later one retries. */
    var everReady = false
        private set

    private var activeHandshake: SessionHandshake? = null
    private var currentEnd: CompletableDeferred<LinkEnd>? = null

    fun forgetReadiness() {
        everReady = false
    }

    /** Cancels a handshake in progress, telling the host when it waits on this phone. False when none is running. */
    fun cancelHandshake(): Boolean {
        val shaking = activeHandshake ?: return false
        shaking.cancel()
        return true
    }

    /** Ends the link being served as [end]; the lifecycle then decides whether to dial again. */
    fun endLink(end: LinkEnd) {
        currentEnd?.complete(end)
    }

    /** One attempt at a control connection, from opening the route until the link ends. */
    suspend fun run(): LinkOutcome = coroutineScope {
        val route = try {
            RouteOpener(target, ports, recorder::note).open()
        } catch (failure: ConnectFailure) {
            return@coroutineScope if (failure.failure.canRetry) {
                LinkOutcome.Unreachable(failure.failure)
            } else {
                LinkOutcome.Refused(failure.failure)
            }
        }
        recorder.note("control connection open over ${route.path}")
        update { if (it.phase is SessionPhase.Connecting) it.copy(phase = SessionPhase.Connecting(route.path)) else it }
        try {
            serveRoute(route)
        } finally {
            coroutineContext.cancelChildren()
            if (link != null) ports.sink.onStop()
            link = null
            currentEnd = null
            services.preview?.failAll()
            route.transport.close()
        }
    }

    private suspend fun CoroutineScope.serveRoute(route: OpenedRoute): LinkOutcome {
        val ended = CompletableDeferred<LinkEnd>()
        currentEnd = ended
        val frames = Channel<Frame>(Channel.UNLIMITED)
        val writer = WriterLoop(route.transport, recorder.tally)
        launchLinkTask(ended) { writer.run() }
        launchLinkTask(ended) {
            ReaderLoop(route.transport.received, frames, recorder.tally) {
                ended.complete(LinkEnd.Terminal(SessionFailure.MalformedFrame))
            }.run()
        }
        val hello = when (val result = handshake(route, writer, frames)) {
            is HandshakeOutcome.Ready -> result.hello
            is HandshakeOutcome.Refused -> {
                writer.flush()
                return LinkOutcome.Refused(SessionFailure.Handshake(result.reason))
            }
            HandshakeOutcome.Cancelled -> {
                writer.flush()
                return LinkOutcome.Cancelled
            }
            is HandshakeOutcome.Lost -> return terminalEnd(ended)?.let(LinkOutcome::Ended)
                ?: LinkOutcome.Unreachable(SessionFailure.ConnectionFailed(ConnectFailureKind.Closed, result.detail))
        }
        val live = startSession(hello, route, writer, frames)
        with(live) { serve(ended) { publish(live) } }
        return LinkOutcome.Ended(ended.await())
    }

    private suspend fun handshake(
        route: OpenedRoute,
        writer: WriterLoop,
        frames: ReceiveChannel<Frame>,
    ): HandshakeOutcome {
        val serverKey = route.transport.peerPublicKey()
            ?: return HandshakeOutcome.Lost("The host closed the connection before it identified itself")
        val config = ClientConfig(
            clientId = ports.identity.clientId,
            clientName = ports.clientName,
            dialledHostId = target.hostId,
            serverKey = serverKey,
            resumeSource = selection.resumeSourceJson(),
            clientPlatform = CLIENT_PLATFORM,
            videoCodecs = ports.videoCodecs,
        )
        val shaking = SessionHandshake(
            config = config,
            pins = ports.pins,
            random = ports.random,
            frames = frames,
            pairingSecret = (target as? ConnectTarget.Pairing)?.qrSecret,
            sendFrame = writer::enqueue,
            awaitDecision = prompt::await,
        )
        activeHandshake = shaking
        try {
            return shaking.run()
        } finally {
            activeHandshake = null
        }
    }

    /** The end a link reached through a malformed frame, which closes the frames before the handshake can read that. */
    private fun terminalEnd(ended: CompletableDeferred<LinkEnd>): LinkEnd.Terminal? =
        if (ended.isCompleted) ended.getCompleted() as? LinkEnd.Terminal else null

    private fun startSession(
        hello: ServerHello,
        route: OpenedRoute,
        writer: WriterLoop,
        frames: ReceiveChannel<Frame>,
    ): ConnectedLink {
        services.attach(hello)
        val live = ConnectedLink(
            hello = hello,
            route = route,
            clock = ports.clock,
            writer = writer,
            frames = frames,
            sink = ports.sink,
            onPicture = onPicture,
            videoConnector = ports.control,
            selection = selection,
            agent = services.agentChat,
            files = services.fileBrowser,
            terminals = services.terminals,
            preview = services.preview,
            relay = ports.relay?.let { RelayConnect(it.signalling, ports.identity, ports.clock) },
            quality = ports.quality.choice(),
            ceiling = QualityCeiling.of(route.path, ports.quality.unlimitedRelay()),
            clipboard = ports.clipboardHistory,
            tally = recorder.tally,
        )
        link = live
        everReady = true
        recorder.note("session ready with ${hello.hostName} over ${route.path}")
        if (route.path == SessionRecord.Path.LAN) ports.lanReached(hello.serverID, route.videoPeer)
        recorder.begin(hello, route.path)
        update {
            it.copy(
                phase = SessionPhase.Ready(
                    hostName = hello.hostName,
                    capabilities = HostCapability.entries.filterTo(mutableSetOf()) { capability -> capability.declaredBy(hello) },
                    path = route.path,
                ),
            )
        }
        return live
    }

    private companion object {
        const val CLIENT_PLATFORM = "android"
    }
}

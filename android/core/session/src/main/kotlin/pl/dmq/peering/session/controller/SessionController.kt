package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.SetVideoEnabled
import kotlin.coroutines.coroutineContext

/**
 * One phone's session with one host, run as a single coroutine tree in [scope]. It connects, pairs when asked, serves the
 * session, and reconnects on the backoff ladder when the link drops, resuming the source the user chose. Call its
 * methods on the scope's dispatcher: the session's state is not guarded by a lock.
 *
 * Commands are accepted only while a session is ready. A command offered earlier is refused rather than held, so no
 * input reaches a host before it has declared what the input needs.
 */
class SessionController(
    private val scope: CoroutineScope,
    private val target: ConnectTarget,
    private val ports: SessionPorts,
    private val history: SessionHistory,
) {
    init {
        require(target !is ConnectTarget.Relay || ports.relay != null) { "a relay target needs the relay ports" }
    }

    private val mutableState = MutableStateFlow(SessionUiState())
    val state: StateFlow<SessionUiState> = mutableState.asStateFlow()

    private val selection = SourceSelection()
    private var reconnect = ReconnectSupervisor()
    private var job: Job? = null
    private var link: ConnectedLink? = null
    private var pairingAnswer: CompletableDeferred<PairingDecision>? = null
    private var pictureEnabled = true
    private var historyId: Long? = null
    private var everReady = false
    private val services = SessionServices(ports) { link }

    /** The agent chat, present once the host has declared that it supports one. */
    val agentChat: AgentChat? get() = services.agentChat

    /** The file browser, present once the host has declared that it supports one. */
    val files: FileBrowser? get() = services.fileBrowser

    /** The agent ids the host declared for chats, or an empty list while no session is ready. */
    val declaredAgentIDs: List<String> get() = link?.hello?.agentChatAgents.orEmpty()

    /** Starts the session. Does nothing while one is already running. */
    fun connect() {
        if (job?.isActive == true) return
        everReady = false
        reconnect = ReconnectSupervisor()
        update { it.copy(phase = SessionPhase.Connecting(target.path)) }
        job = scope.launch { lifecycle() }
    }

    /**
     * The user's answer to the six digits shown on both screens. [secret] is the QR code's secret when the digits were
     * read from a code. Ignored when no code is waiting.
     */
    fun confirmPairing(accepted: Boolean, secret: ByteArray? = null) {
        pairingAnswer?.complete(PairingDecision(accepted, secret))
    }

    /** Sends [command] to the host. False when the session is not ready or the host did not declare what it needs. */
    fun send(command: RemoteCommand): Boolean {
        val live = link ?: return false
        if (!accepts(live, command)) return false
        live.commands.offer(command)
        return true
    }

    /** Switches the picture to [source] and remembers it for a reconnect. False when the switch cannot be sent. */
    fun chooseSource(source: CaptureSource): Boolean {
        val live = link ?: return false
        if (!accepts(live, SetCaptureSource(source))) return false
        live.commands.offer(selection.choose(source))
        return true
    }

    /** Pauses or resumes the host's video. The picture reads as paused only when the host accepted the change. */
    fun setPictureEnabled(enabled: Boolean): Boolean {
        val sent = send(SetVideoEnabled(enabled))
        if (sent) {
            pictureEnabled = enabled
            link?.let(::publish)
        }
        return sent
    }

    /** Applies the stream quality to the live session. False when no session is running. */
    fun setQuality(choice: QualityChoice): Boolean {
        val live = link ?: return false
        live.applyQuality(choice, QualityCeiling.of(live.path, ports.quality.unlimitedRelay()))
        return true
    }

    /** The network moved, so the reconnect ladder starts again from its shortest step. */
    fun networkChanged() {
        reconnect.networkChanged()
    }

    /** Ends the session now. The phone does not reconnect afterwards. */
    fun disconnect() {
        if (job?.isActive != true) return
        job?.cancel()
        endHistory(SessionRecord.EndReason.USER_ENDED)
        update { it.copy(phase = SessionPhase.Ended) }
    }

    private suspend fun lifecycle() {
        while (true) {
            when (val outcome = runLink()) {
                is LinkOutcome.Refused -> return fail(outcome.failure)
                is LinkOutcome.Unreachable -> if (!everReady) return fail(outcome.failure)
                is LinkOutcome.Ended -> when (val end = outcome.end) {
                    LinkEnd.HostStopped -> return stopped()
                    is LinkEnd.Terminal -> return fail(end.failure)
                    LinkEnd.Lost -> Unit
                }
            }
            val step = reconnect.nextStep() ?: return fail(SessionFailure.ConnectionLost)
            update { it.copy(phase = SessionPhase.Reconnecting(reconnect.attempt)) }
            reconnect.waitFor(step)
        }
    }

    /** One attempt at a control connection, from opening the route until the link ends. */
    private suspend fun runLink(): LinkOutcome = coroutineScope {
        val route = try {
            RouteOpener(target, ports).open()
        } catch (failure: ConnectFailure) {
            return@coroutineScope if (failure.failure.canRetry) {
                LinkOutcome.Unreachable(failure.failure)
            } else {
                LinkOutcome.Refused(failure.failure)
            }
        }
        val ended = CompletableDeferred<LinkEnd>()
        val frames = Channel<Frame>(Channel.UNLIMITED)
        val writer = WriterLoop(route.transport)
        try {
            launchLinkTask(ended) { writer.run() }
            launchLinkTask(ended) {
                ReaderLoop(route.transport.received, frames) {
                    ended.complete(LinkEnd.Terminal(SessionFailure.MalformedFrame))
                }.run()
            }
            val hello = when (val result = handshake(route, writer, frames)) {
                is HandshakeOutcome.Ready -> result.hello
                is HandshakeOutcome.Refused -> return@coroutineScope LinkOutcome.Refused(SessionFailure.Handshake(result.reason))
                HandshakeOutcome.Lost -> return@coroutineScope terminalEnd(ended)?.let(LinkOutcome::Ended)
                    ?: LinkOutcome.Unreachable(SessionFailure.Unreachable)
            }
            val live = startSession(hello, route, writer, frames)
            with(live) { serve(ended) { publish(live) } }
            LinkOutcome.Ended(ended.await())
        } finally {
            coroutineContext.cancelChildren()
            if (link != null) ports.sink.onStop()
            link = null
            route.transport.close()
        }
    }

    private suspend fun handshake(
        route: OpenedRoute,
        writer: WriterLoop,
        frames: ReceiveChannel<Frame>,
    ): HandshakeOutcome {
        val serverKey = route.transport.peerPublicKey() ?: return HandshakeOutcome.Lost
        val config = ClientConfig(
            clientId = ports.identity.clientId,
            clientName = ports.clientName,
            dialledHostId = target.hostId,
            serverKey = serverKey,
            resumeSource = selection.resumeSourceJson(),
            clientPlatform = CLIENT_PLATFORM,
        )
        return SessionHandshake(
            config = config,
            pins = ports.pins,
            random = ports.random,
            frames = frames,
            pairingSecret = (target as? ConnectTarget.Pairing)?.qrSecret,
            sendFrame = writer::enqueue,
            awaitDecision = ::awaitPairing,
        ).run()
    }

    /** The end a link reached through a malformed frame, which closes the frames before the handshake can read that. */
    private fun terminalEnd(ended: CompletableDeferred<LinkEnd>): LinkEnd.Terminal? =
        if (ended.isCompleted) ended.getCompleted() as? LinkEnd.Terminal else null

    private suspend fun awaitPairing(code: String): PairingDecision {
        update { it.copy(phase = SessionPhase.ConfirmingPairing(code)) }
        val answer = CompletableDeferred<PairingDecision>()
        pairingAnswer = answer
        val decision = answer.await()
        pairingAnswer = null
        update { it.copy(phase = SessionPhase.Connecting(target.path)) }
        return decision
    }

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
            onPicture = ::pictureArrived,
            selection = selection,
            agent = services.agentChat,
            files = services.fileBrowser,
            relay = ports.relay?.let { RelayConnect(it.signalling, ports.identity, ports.clock) },
            quality = ports.quality.choice(),
            ceiling = QualityCeiling.of(route.path, ports.quality.unlimitedRelay()),
        )
        link = live
        everReady = true
        if (historyId == null) {
            historyId = history.begin(hello.serverID, hello.hostName, target.path, nowMillis())
        }
        update {
            it.copy(
                phase = SessionPhase.Ready(
                    hostName = hello.hostName,
                    capabilities = HostCapability.entries.filterTo(mutableSetOf()) { capability -> capability.declaredBy(hello) },
                    path = target.path,
                ),
            )
        }
        return live
    }

    private fun pictureArrived() {
        reconnect.pictureArrived()
        link?.let(::publish)
    }

    private fun publish(live: ConnectedLink) {
        update {
            it.copy(
                catalogue = live.commands.latestCatalog ?: it.catalogue,
                activeSource = selection.chosen,
                latencyMillis = live.latencyMillis,
                picture = live.pictureState(paused = !pictureEnabled),
                notice = live.notice,
                phase = it.phase.withPath(live.path),
                qualityCeiling = QualityCeiling.of(live.path, ports.quality.unlimitedRelay()),
            )
        }
    }

    private fun accepts(live: ConnectedLink, command: RemoteCommand): Boolean {
        val required = HostCapability.requiredBy(command) ?: return true
        return required.declaredBy(live.hello)
    }

    private fun stopped() {
        endHistory(SessionRecord.EndReason.HOST_STOPPED)
        update { it.copy(phase = SessionPhase.Ended) }
    }

    private fun fail(failure: SessionFailure) {
        val reason = if (failure == SessionFailure.ConnectionLost) {
            SessionRecord.EndReason.CONNECTION_LOST
        } else {
            SessionRecord.EndReason.FAILED
        }
        endHistory(reason)
        update { it.copy(phase = SessionPhase.Failed(failure, failure.canRetry)) }
    }

    private fun endHistory(reason: SessionRecord.EndReason) {
        val id = historyId ?: return
        history.end(id, nowMillis(), reason)
        historyId = null
    }

    private fun SessionPhase.withPath(path: SessionRecord.Path): SessionPhase =
        if (this is SessionPhase.Ready && this.path != path) copy(path = path) else this

    private fun nowMillis(): Long = ports.clock.unixSeconds() * MILLIS_PER_SECOND

    private fun update(transform: (SessionUiState) -> SessionUiState) {
        mutableState.update(transform)
    }

    private companion object {
        const val MILLIS_PER_SECOND = 1000L
        const val CLIENT_PLATFORM = "android"
    }
}

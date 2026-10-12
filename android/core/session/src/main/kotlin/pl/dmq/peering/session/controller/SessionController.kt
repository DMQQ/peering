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
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.clipboard.ClipboardDirection
import pl.dmq.peering.session.clipboard.ClipboardHistory
import pl.dmq.peering.session.clipboard.ClipboardPush
import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.PushClipboard
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
    @Volatile private var pendingCode: PendingCode? = null
    private var activeHandshake: SessionHandshake? = null
    private var pictureEnabled = true
    private var historyId: Long? = null
    private var everReady = false
    private val services = SessionServices(ports) { link }

    /** The agent chat, present once the host has declared that it supports one. */
    val agentChat: AgentChat? get() = services.agentChat

    /** The file browser, present once the host has declared that it supports one. */
    val files: FileBrowser? get() = services.fileBrowser

    /** The shells of the computer, present once a session has been ready. */
    val terminals: TerminalSessions? get() = services.terminals

    /** The agent ids the host declared for chats (Claude Code and Codex for a host that predates the list), or none while no session is ready. */
    val declaredAgentIDs: List<String> get() = link?.hello?.let(AgentCapabilities::declaredAgents).orEmpty()

    /** Starts the session. Does nothing while one is already running. */
    fun connect() {
        if (job?.isActive == true) return
        everReady = false
        reconnect = ReconnectSupervisor()
        update { it.copy(phase = SessionPhase.Connecting(target.path)) }
        job = scope.launch { lifecycle() }
    }

    /** The six digits the user typed. Ignored, and read as a mismatch, when no code is awaited. */
    fun submitPairingCode(digits: String): CodeCheck = submitCode(digits, null)

    /** The code read from the Mac's QR code, with the secret it carried. */
    fun submitScannedPairingCode(code: String, secret: ByteArray?): CodeCheck = submitCode(code, secret)

    private fun submitCode(entry: String, secret: ByteArray?): CodeCheck {
        val pending = pendingCode ?: return CodeCheck.Mismatch
        val check = pending.gate.check(entry)
        when (check) {
            CodeCheck.Match -> pending.answer.complete(PairingDecision(accepted = true, secret = secret))
            CodeCheck.TooManyAttempts -> pending.answer.complete(PairingDecision(accepted = false, secret = null))
            CodeCheck.Mismatch -> update {
                it.copy(phase = SessionPhase.EnteringPairingCode(pending.gate.wrongAttempts, PairingCodeError.WrongCode))
            }
        }
        return check
    }

    /** Sends [command] to the host. False when the session is not ready or the host did not declare what it needs. */
    fun send(command: RemoteCommand): Boolean {
        if (command is SetCaptureSource) return chooseSource(command.source)
        val live = link ?: return false
        if (!accepts(live, command)) return false
        live.commands.offer(command)
        if (command is PushClipboard) ports.clipboardHistory.record(ClipboardContent.Text(command.text), ClipboardDirection.TO_COMPUTER)
        return true
    }

    /** The clipboards that moved, newest first. It outlives the session when the ports share one history. */
    val clipboardHistory: ClipboardHistory get() = ports.clipboardHistory

    /** Sends a picture to the computer's clipboard. */
    fun sendClipboardImage(png: ByteArray): ClipboardPush = link?.sendClipboardImage(png) ?: ClipboardPush.NotReady

    /** Switches the picture to [source] and remembers it for a reconnect. False when the switch cannot be sent. */
    fun chooseSource(source: CaptureSource): Boolean {
        val live = link ?: return false
        if (!accepts(live, SetCaptureSource(source))) return false
        live.commands.offer(selection.choose(source))
        update { it.copy(activeSource = selection.chosen, rememberedMosaic = selection.rememberedMosaic) }
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

    /** Reopens the picture after it stalled or failed. False when no session is running. */
    fun retryPicture(): Boolean {
        val live = link ?: return false
        live.retryPicture()
        publish(live)
        return true
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
    fun disconnect() = stop(SessionPhase.Ended)

    /**
     * Abandons a connection or pairing that has not become a session: the host is told when it waits on this phone, the
     * connection is closed, and the phase returns to [SessionPhase.Idle]. Does nothing once a session is ready or failed.
     */
    fun cancelPairing() {
        val phase = state.value.phase
        if (phase is SessionPhase.Connecting || phase is SessionPhase.EnteringPairingCode) stop(SessionPhase.Idle)
    }

    private fun stop(phase: SessionPhase) {
        if (job?.isActive != true) return
        val pairing = activeHandshake
        if (pairing != null) {
            // The handshake tells the host and ends the link itself, so its decline is written before the close.
            pairing.cancel()
        } else {
            job?.cancel()
        }
        endHistory(SessionRecord.EndReason.USER_ENDED)
        update { it.copy(phase = phase) }
    }

    private suspend fun lifecycle() {
        while (true) {
            when (val outcome = runLink()) {
                LinkOutcome.Cancelled -> return
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
        ports.log.log("control connection open over ${route.path}")
        update { if (it.phase is SessionPhase.Connecting) it.copy(phase = SessionPhase.Connecting(route.path)) else it }
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
                is HandshakeOutcome.Refused -> {
                    writer.flush()
                    return@coroutineScope LinkOutcome.Refused(SessionFailure.Handshake(result.reason))
                }
                HandshakeOutcome.Cancelled -> {
                    writer.flush()
                    return@coroutineScope LinkOutcome.Cancelled
                }
                is HandshakeOutcome.Lost -> return@coroutineScope terminalEnd(ended)?.let(LinkOutcome::Ended)
                    ?: LinkOutcome.Unreachable(SessionFailure.ConnectionFailed(ConnectFailureKind.Closed, result.detail))
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
        val serverKey = route.transport.peerPublicKey() ?: return HandshakeOutcome.Lost("The host closed the connection before it identified itself")
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
            awaitDecision = ::awaitPairing,
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

    private suspend fun awaitPairing(code: String): PairingDecision {
        (target as? ConnectTarget.Pairing)?.qrSecret?.let { return PairingDecision(accepted = true, secret = it) }
        update { it.copy(phase = SessionPhase.EnteringPairingCode(attempts = 0)) }
        val pending = PendingCode(PairingCodeGate(code), CompletableDeferred())
        pendingCode = pending
        try {
            val decision = pending.answer.await()
            update { it.copy(phase = SessionPhase.Connecting(target.path)) }
            return decision
        } finally {
            pendingCode = null
        }
    }

    private class PendingCode(val gate: PairingCodeGate, val answer: CompletableDeferred<PairingDecision>)

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
            videoConnector = ports.control,
            selection = selection,
            agent = services.agentChat,
            files = services.fileBrowser,
            terminals = services.terminals,
            relay = ports.relay?.let { RelayConnect(it.signalling, ports.identity, ports.clock) },
            quality = ports.quality.choice(),
            ceiling = QualityCeiling.of(route.path, ports.quality.unlimitedRelay()),
            clipboard = ports.clipboardHistory,
        )
        link = live
        everReady = true
        if (route.path == SessionRecord.Path.LAN) ports.lanReached(hello.serverID, route.videoPeer)
        if (historyId == null) {
            historyId = history.begin(hello.serverID, hello.hostName, route.path, nowMillis())
        }
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

    private fun pictureArrived() {
        reconnect.pictureArrived()
        link?.let(::publish)
    }

    private fun publish(live: ConnectedLink) {
        update {
            it.copy(
                catalogue = live.commands.latestCatalog ?: it.catalogue,
                activeSource = selection.chosen,
                rememberedMosaic = selection.rememberedMosaic,
                latencyMillis = live.latencyMillis,
                picture = live.pictureState(paused = !pictureEnabled),
                notice = live.notice,
                hostClipboard = live.hostClipboard,
                hostPointer = live.hostPointer,
                phase = it.phase.withPath(live.path),
                qualityCeiling = QualityCeiling.of(live.path, ports.quality.unlimitedRelay()),
                directPath = live.directPathState,
                videoStream = live.videoStream,
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

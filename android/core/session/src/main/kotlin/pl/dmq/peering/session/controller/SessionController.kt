package pl.dmq.peering.session.controller

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.clipboard.ClipboardDirection
import pl.dmq.peering.session.clipboard.ClipboardHistory
import pl.dmq.peering.session.clipboard.ClipboardPush
import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PushClipboard
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.SetVideoEnabled

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
    private var reconnect = ReconnectSupervisor(ports.clock)
    private var job: Job? = null
    private var pictureEnabled = true
    private val recorder = SessionRecorder(ports, history)
    private val prompt = PairingPrompt(target, ::update)
    private val services: SessionServices = SessionServices(ports) { runner.link }
    private val runner = LinkRunner(target, ports, selection, services, recorder, prompt, ::update, ::pictureArrived, ::publish)
    private val link: ConnectedLink? get() = runner.link

    /** The agent chat, present once the host has declared that it supports one. */
    val agentChat: AgentChat? get() = services.agentChat

    /** The file browser, present once the host has declared that it supports one. */
    val files: FileBrowser? get() = services.fileBrowser

    /** The shells of the computer, present once a session has been ready. */
    val terminals: TerminalSessions? get() = services.terminals

    /** The web preview's way to the computer's loopback; null until a computer that supports agent chats is connected. */
    val preview: PreviewProxyClient? get() = services.preview

    /** The agent ids the host declared for chats (Claude Code and Codex for a host that predates the list), or none while no session is ready. */
    val declaredAgentIDs: List<String> get() = link?.hello?.let(AgentCapabilities::declaredAgents).orEmpty()

    /** Starts the session. Does nothing while one is already running. */
    fun connect() {
        if (job?.isActive == true) return
        runner.forgetReadiness()
        reconnect = ReconnectSupervisor(ports.clock)
        update { it.copy(phase = SessionPhase.Connecting(target.path)) }
        job = scope.launch { lifecycle() }
    }

    /** The six digits the user typed. Ignored, and read as a mismatch, when no code is awaited. */
    fun submitPairingCode(digits: String): CodeCheck = submitCode(digits, null)

    /** The code read from the Mac's QR code, with the secret it carried. */
    fun submitScannedPairingCode(code: String, secret: ByteArray?): CodeCheck = submitCode(code, secret)

    private fun submitCode(entry: String, secret: ByteArray?): CodeCheck = prompt.submit(entry, secret)

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

    /**
     * The network moved, so the reconnect ladder starts again from its shortest step.
     */
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
        // The handshake tells the host and ends the link itself, so its decline is written before the close.
        if (!runner.cancelHandshake()) job?.cancel()
        recorder.end(SessionRecord.EndReason.USER_ENDED)
        update { it.copy(phase = phase) }
    }

    private suspend fun lifecycle() {
        while (true) {
            when (val outcome = runner.run()) {
                LinkOutcome.Cancelled -> return
                is LinkOutcome.Refused -> return fail(outcome.failure)
                is LinkOutcome.Unreachable -> if (!runner.everReady) return fail(outcome.failure)
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
        recorder.end(SessionRecord.EndReason.HOST_STOPPED)
        update { it.copy(phase = SessionPhase.Ended) }
    }

    private fun fail(failure: SessionFailure) {
        val reason = if (failure == SessionFailure.ConnectionLost) {
            SessionRecord.EndReason.CONNECTION_LOST
        } else {
            SessionRecord.EndReason.FAILED
        }
        recorder.end(reason)
        update { it.copy(phase = SessionPhase.Failed(failure, failure.canRetry)) }
    }

    private fun SessionPhase.withPath(path: SessionRecord.Path): SessionPhase =
        if (this is SessionPhase.Ready && this.path != path) copy(path = path) else this

    private fun update(transform: (SessionUiState) -> SessionUiState) {
        mutableState.update(transform)
    }
}

package pl.dmq.peering.session.controller

import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.ChunkException
import pl.dmq.peering.wire.ClipboardPayload
import pl.dmq.peering.wire.MAX_CLIPBOARD_REASSEMBLED_BYTES
import pl.dmq.peering.wire.VideoChunkReassembler
import pl.dmq.peering.wire.ErrorPayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.NoticePayload
import pl.dmq.peering.wire.PreviewProxyEvent
import pl.dmq.peering.wire.TerminalEvent

/** Sends each frame of a live control connection to the part that owns it, and says what the link must do about it. */
internal class FrameRouter(
    private val liveness: LivenessMonitor,
    private val commands: SessionCommands,
    private val lanes: VideoLanes,
    private val selection: SourceSelection,
    private val agent: AgentChat?,
    private val files: FileBrowser?,
    private val terminals: TerminalSessions?,
    private val preview: PreviewProxyClient? = null,
) {
    private val clipboardChunks = VideoChunkReassembler(MAX_CLIPBOARD_REASSEMBLED_BYTES)

    fun route(frame: Frame): List<SessionEvent> = when (frame.kind) {
        MessageKind.Pong -> {
            liveness.onPong(frame)
            laneEvents(frame)
        }
        MessageKind.Catalog -> onCatalog(frame)
        MessageKind.VideoConfig -> {
            selection.onVideoConfig()
            laneEvents(frame)
        }
        MessageKind.VideoChunk -> if (isClipboardChunk(frame)) onClipboardChunk(frame) else laneEvents(frame)
        MessageKind.VideoFrame, MessageKind.VideoKey, MessageKind.AudioConfig, MessageKind.AudioFrame -> laneEvents(frame)
        MessageKind.AgentEvent -> {
            routeAgent(frame)
            emptyList()
        }
        MessageKind.TerminalEvent -> {
            routeTerminal(frame)
            emptyList()
        }
        MessageKind.PreviewEvent -> {
            HandshakeFrames.parsed { PreviewProxyEvent.parse(frame.payload.decodeToString()) }?.let { preview?.onEvent(it) }
            emptyList()
        }
        MessageKind.Error -> onError(frame)
        MessageKind.Notice -> onNotice(frame)
        MessageKind.ClipboardContent -> onClipboard(frame)
        MessageKind.PointerReport -> onPointerReport(frame)
        else -> emptyList()
    }

    private fun onPointerReport(frame: Frame): List<SessionEvent> {
        val point = HandshakeFrames.decode(frame, NormalizedPoint.serializer()) ?: return emptyList()
        return listOf(SessionEvent.HostPointerMoved(point.clamped()))
    }

    private fun onClipboard(frame: Frame): List<SessionEvent> {
        val clipboard = HandshakeFrames.decode(frame, ClipboardPayload.serializer()) ?: return emptyList()
        val png = clipboard.pngBytes
        val content = if (png != null) ClipboardContent.Image(png) else ClipboardContent.Text(clipboard.plainText.orEmpty())
        return listOf(SessionEvent.HostClipboard(content))
    }

    /** A picture from the computer is chunked like the picture stream is, and must not reach that stream's reassembler. */
    private fun isClipboardChunk(frame: Frame): Boolean =
        frame.payload.firstOrNull()?.toInt()?.and(0xFF) == MessageKind.ClipboardContent.byte

    private fun onClipboardChunk(frame: Frame): List<SessionEvent> {
        val whole = try {
            clipboardChunks.ingest(frame)
        } catch (error: ChunkException) {
            null
        }
        return whole?.let(::onClipboard).orEmpty()
    }

    private fun laneEvents(frame: Frame): List<SessionEvent> = lanes.onControlFrame(frame).asEvents()

    private fun onCatalog(frame: Frame): List<SessionEvent> {
        val catalog = commands.onCatalog(frame) ?: return emptyList()
        return listOfNotNull(selection.onCatalog(catalog)?.let { SessionEvent.Offer(it) })
    }

    private fun routeAgent(frame: Frame) {
        val chat = agent ?: return
        HandshakeFrames.parsed { AgentEvent.parse(frame.payload.decodeToString()) }?.let(chat::onEvent)
    }

    private fun routeTerminal(frame: Frame) {
        val event = HandshakeFrames.parsed { TerminalEvent.parse(frame.payload.decodeToString()) } ?: return
        files?.onEvent(event)
        terminals?.onEvent(event)
    }

    private fun onError(frame: Frame): List<SessionEvent> {
        val error = HandshakeFrames.decode(frame, ErrorPayload.serializer()) ?: return emptyList()
        return listOf(
            when (error.code) {
                ErrorPayload.HOST_STOPPED_CODE -> SessionEvent.Finish(LinkEnd.HostStopped)
                QUOTA_CODE -> SessionEvent.Finish(LinkEnd.Terminal(SessionFailure.Quota))
                else -> SessionEvent.Notice(error.message)
            },
        )
    }

    private fun onNotice(frame: Frame): List<SessionEvent> {
        val notice = HandshakeFrames.decode(frame, NoticePayload.serializer()) ?: return emptyList()
        return listOf(SessionEvent.Notice(notice.message))
    }

    private companion object {
        /** The relay's code for a session that has used up the day's free time. */
        const val QUOTA_CODE = "quotaExceeded"
    }
}

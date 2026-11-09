package pl.dmq.peering.session.controller

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ServerHello

/**
 * The agent chat and the file browser of one phone. Each is created on the first link, and it outlives the links
 * it is used on: its requests go out on whichever link is current, and a request made while the link is down is dropped.
 */
internal class SessionServices(private val ports: SessionPorts, private val currentLink: () -> ConnectedLink?) {
    var agentChat: AgentChat? = null
        private set

    var fileBrowser: FileBrowser? = null
        private set

    var terminals: TerminalSessions? = null
        private set

    /** Pages from the computer's loopback for the web preview; exists where agent chats do, since that is where the preview is offered. */
    var preview: PreviewProxyClient? = null
        private set

    fun attach(hello: ServerHello) {
        if (terminals == null) {
            terminals = TerminalSessions(
                send = { request ->
                    currentLink()?.enqueue(Frame(MessageKind.TerminalRequest, request.toJson().toByteArray(Charsets.UTF_8)))
                },
                scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            )
        }
        if (agentChat == null) {
            agentChat = AgentChat { request ->
                currentLink()?.enqueue(Frame(MessageKind.AgentRequest, request.toJson().toByteArray(Charsets.UTF_8)))
            }
        }
        if (preview == null) {
            preview = PreviewProxyClient(transmit = { command ->
                currentLink()?.enqueue(Frame(MessageKind.PreviewRequest, command.toJson().toByteArray(Charsets.UTF_8))) != null
            })
        }
        if (fileBrowser == null) {
            fileBrowser = FileBrowser(
                send = { request ->
                    currentLink()?.enqueue(Frame(MessageKind.TerminalRequest, request.toJson().toByteArray(Charsets.UTF_8)))
                },
                writeDownloadRange = ports.downloads::writeRange,
                downloadBacklog = { ports.downloads.backlog },
            )
        }
    }
}

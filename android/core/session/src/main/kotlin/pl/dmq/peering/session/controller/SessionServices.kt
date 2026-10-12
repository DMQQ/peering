package pl.dmq.peering.session.controller

import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ServerHello

/**
 * The agent chat and the file browser of one phone. Each exists once the host declares it, and it outlives the links
 * it is used on: its requests go out on whichever link is current, and a request made while the link is down is dropped.
 */
internal class SessionServices(private val ports: SessionPorts, private val currentLink: () -> ConnectedLink?) {
    var agentChat: AgentChat? = null
        private set

    var fileBrowser: FileBrowser? = null
        private set

    fun attach(hello: ServerHello) {
        if (hello.supportsAgentChat == true && agentChat == null) {
            agentChat = AgentChat(AgentCapabilities.declaredBy(hello)) { request ->
                currentLink()?.enqueue(Frame(MessageKind.AgentRequest, request.toJson().toByteArray(Charsets.UTF_8)))
            }
        }
        if (hello.supportsFileBrowser == true && fileBrowser == null) {
            fileBrowser = FileBrowser(
                supportsFileBrowser = true,
                send = { request ->
                    currentLink()?.enqueue(Frame(MessageKind.TerminalRequest, request.toJson().toByteArray(Charsets.UTF_8)))
                },
                writeDownloadRange = ports.downloads::writeRange,
            )
        }
    }
}

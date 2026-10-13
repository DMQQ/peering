package pl.dmq.peering.session.flows

import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentStreamEvent
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.AgentTurnSummary

/**
 * A Mac's agent side, scripted. It numbers each chat's stream and replays it for History requests. Each prompt runs the
 * next queued turn; the turn stops at its first ask and goes on only once the phone answers that ask, as the CLI does.
 */
class ScriptedAgentHost {
    private val chats = linkedMapOf<String, HostChat>()
    private val turns = ArrayDeque<List<AgentStreamPayload>>()
    private var chatCount = 0

    fun queueTurn(payloads: List<AgentStreamPayload>) {
        turns.addLast(payloads)
    }

    fun reply(request: AgentRequest): List<AgentEvent> = when (request) {
        is AgentRequest.ListSessions -> listOf(AgentEvent.Snapshot(chats.values.map { it.info }))
        is AgentRequest.Start -> start(request)
        is AgentRequest.History -> replay(request)
        is AgentRequest.Prompt -> runTurn(request.sessionID, request.text)
        is AgentRequest.Approval -> resolveAsk(request)
        is AgentRequest.Interrupt -> interrupt(request.sessionID)
        else -> emptyList()
    }

    private fun start(request: AgentRequest.Start): List<AgentEvent> {
        chatCount += 1
        val id = "S$chatCount"
        val info = AgentSessionInfo(
            id = id,
            agentID = request.agentID,
            title = "Chat $id",
            directory = request.directory ?: "/",
            state = AgentSessionState.IDLE,
            lastIndex = 0,
            createdAt = 0.0,
        )
        val chat = HostChat(id, info)
        chats[id] = chat
        chat.emit(AgentStreamPayload.SessionReady(agentID = request.agentID, directory = info.directory))
        return listOf(AgentEvent.Created(info))
    }

    private fun replay(request: AgentRequest.History): List<AgentEvent> {
        val chat = checkNotNull(chats[request.sessionID]) { "no chat ${request.sessionID}" }
        val events = chat.events.filter { it.index > request.since }
        return listOf(AgentEvent.Replay(chat.id, events, isLast = true, truncatedAtFront = false))
    }

    private fun runTurn(sessionID: String, text: String): List<AgentEvent> {
        val chat = checkNotNull(chats[sessionID]) { "no chat $sessionID" }
        val script = checkNotNull(turns.removeFirstOrNull()) { "no turn is scripted for the prompt '$text'" }
        val ask = script.indexOfFirst { it is AgentStreamPayload.ApprovalRequested }
        val running = if (ask < 0) script else script.subList(0, ask + 1)
        chat.held = if (ask < 0) emptyList() else script.subList(ask + 1, script.size)
        return (listOf(AgentStreamPayload.UserPrompt(text)) + running).map(chat::emit)
    }

    private fun resolveAsk(request: AgentRequest.Approval): List<AgentEvent> {
        val chat = checkNotNull(chats[request.sessionID]) { "no chat ${request.sessionID}" }
        val resolved = chat.emit(AgentStreamPayload.ApprovalResolved(request.approvalID, request.decision))
        val tail = chat.held.map(chat::emit)
        chat.held = emptyList()
        return listOf(resolved) + tail
    }

    private fun interrupt(sessionID: String): List<AgentEvent> {
        val chat = checkNotNull(chats[sessionID]) { "no chat $sessionID" }
        chat.held = emptyList()
        return listOf(chat.emit(AgentStreamPayload.TurnFinished(AgentTurnSummary(ok = false, stopped = true))))
    }

    private class HostChat(val id: String, val info: AgentSessionInfo) {
        val events = mutableListOf<AgentStreamEvent>()
        var held: List<AgentStreamPayload> = emptyList()

        fun emit(payload: AgentStreamPayload): AgentEvent {
            val event = AgentStreamEvent(events.size + 1L, payload)
            events += event
            return AgentEvent.Stream(id, event)
        }
    }
}

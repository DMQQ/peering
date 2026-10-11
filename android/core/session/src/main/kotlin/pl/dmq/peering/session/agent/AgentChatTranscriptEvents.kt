package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentStreamPayload

/** A live event. An event past a gap makes the chat ask for history since the last index it holds. */
internal fun stream(state: AgentChatState, event: AgentEvent.Stream): AgentChatStep {
    val session = state.session(event.sessionID) ?: return AgentChatStep(state)
    val transcript = TranscriptReducer.reduce(session.transcript, event.event)
    val payload = event.event.payload
    val model = (payload as? AgentStreamPayload.SessionReady)?.model ?: session.info.model
    val info = session.info.copy(state = transcript.sessionState, model = model)
    return settle(state, session.copy(transcript = transcript, info = info, failure = null))
}

/** A history chunk. The first chunk from index 1 is the whole conversation, so it replaces what the phone held. */
internal fun replay(state: AgentChatState, event: AgentEvent.Replay): AgentChatStep {
    val session = state.session(event.sessionID) ?: return AgentChatStep(state)
    val base = if (event.events.firstOrNull()?.index == 1L) TranscriptState() else session.transcript
    val transcript = TranscriptReducer.replay(base, event.events, event.isLast, event.truncatedAtFront)
    val info = if (event.events.isEmpty()) session.info else session.info.copy(state = transcript.sessionState)
    val loaded = session.copy(
        transcript = transcript,
        info = info,
        historyLoaded = true,
        historyRequested = !event.isLast,
    )
    return settle(state, loaded)
}

/**
 * What follows any change to a chat: a queued prompt goes out once the chat is idle, and a chat with a gap or no
 * history yet asks for it. A prompt that goes out marks the chat working, so a second prompt does not overtake it.
 */
private fun settle(state: AgentChatState, session: AgentChatSession): AgentChatStep {
    val (queue, release) = session.prompts.release(session.state)
    var next = session.copy(prompts = queue)
    val requests = mutableListOf<AgentRequest>()
    if (release is PromptRelease.Send) {
        next = next.markWorking()
        requests += AgentRequest.Prompt(session.id, release.text)
    }
    if (next.needsHistory) {
        val (asked, request) = next.askHistory()
        next = asked
        requests += request
    }
    return AgentChatStep(state.replacingSession(next), requests)
}

/** Marks the session as asked for history from its last index, and returns the request that asks. */
internal fun AgentChatSession.askHistory(): Pair<AgentChatSession, AgentRequest.History> =
    copy(historyRequested = true) to AgentRequest.History(id, since = transcript.lastIndex)

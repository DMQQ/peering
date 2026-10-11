package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentRequest

/** What the user asks for in a chat. Each returns the next state and the requests that go to the Mac. */
internal object AgentChatIntents {
    fun select(state: AgentChatState, sessionID: String): AgentChatStep {
        val session = state.session(sessionID) ?: return AgentChatStep(state)
        val selected = state.copy(selectedSessionID = sessionID)
        if (session.historyLoaded || session.historyRequested) return AgentChatStep(selected)
        val (asked, request) = session.askHistory()
        return AgentChatStep(selected.replacingSession(asked), listOf(request))
    }

    /** Blank text is dropped. A prompt behind a turn in flight is queued and goes out when the turn ends. */
    fun prompt(state: AgentChatState, text: String): AgentChatStep {
        val session = state.selected ?: return AgentChatStep(state)
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return AgentChatStep(state)
        val (queue, submission) = session.prompts.submit(trimmed, session.state)
        val queued = session.copy(prompts = queue, failure = null)
        return if (submission == PromptSubmission.SEND) {
            AgentChatStep(state.replacingSession(queued.markWorking()), listOf(AgentRequest.Prompt(session.id, trimmed)))
        } else {
            AgentChatStep(state.replacingSession(queued))
        }
    }

    /** Only an ask still pending on the Mac is answered; an answer for any other id is dropped. */
    fun approve(state: AgentChatState, approvalID: String, answer: ApprovalAnswer): AgentChatStep {
        val session = state.selected ?: return AgentChatStep(state)
        val request = answerRequest(session.id, state.openApprovals, approvalID, answer)
            ?: return AgentChatStep(state)
        return AgentChatStep(state, listOf(request))
    }
}

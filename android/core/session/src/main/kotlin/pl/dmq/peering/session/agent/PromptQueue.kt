package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentSessionState

enum class PromptSubmission {
    SEND,
    QUEUED,
}

sealed class PromptRelease {
    data class Send(val text: String) : PromptRelease()

    data object Hold : PromptRelease()

    /** The chat failed or ended, so the waiting prompts are discarded rather than sent into the next chat. */
    data object Dropped : PromptRelease()
}

/**
 * Messages typed while a turn runs. The Mac takes one question at a time, so the rest wait here and go out one
 * per finished turn. Interrupting a turn does not clear the queue: the stopped turn ends idle, and the next
 * waiting prompt is released like any other.
 */
data class PromptQueue(val prompts: List<String> = emptyList()) {
    /** Behind a turn in flight, or behind messages already waiting, so the order is the order typed. */
    fun submit(text: String, sessionState: AgentSessionState?): Pair<PromptQueue, PromptSubmission> {
        val mustWait = sessionState == AgentSessionState.WORKING ||
            sessionState == AgentSessionState.AWAITING_APPROVAL ||
            prompts.isNotEmpty()
        return if (mustWait) copy(prompts = prompts + text) to PromptSubmission.QUEUED else this to PromptSubmission.SEND
    }

    fun remove(offset: Int): PromptQueue =
        if (offset in prompts.indices) copy(prompts = prompts.filterIndexed { index, _ -> index != offset }) else this

    fun release(state: AgentSessionState): Pair<PromptQueue, PromptRelease> {
        if (prompts.isEmpty()) return this to PromptRelease.Hold
        return when (state) {
            AgentSessionState.IDLE -> copy(prompts = prompts.drop(1)) to PromptRelease.Send(prompts.first())
            AgentSessionState.FAILED, AgentSessionState.EXITED -> PromptQueue() to PromptRelease.Dropped
            AgentSessionState.WORKING, AgentSessionState.AWAITING_APPROVAL -> this to PromptRelease.Hold
        }
    }
}

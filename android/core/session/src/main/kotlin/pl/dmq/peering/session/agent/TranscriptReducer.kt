package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentPlanStep
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentStreamEvent
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.AgentTurnSummary

/** Folds an agent session's stream events into its conversation. Pure: every call returns a new state. */
object TranscriptReducer {
    /** Applies one live event. A repeat is ignored; one past a gap is withheld until a replay fills the gap. */
    fun reduce(state: TranscriptState, event: AgentStreamEvent): TranscriptState = when {
        event.index <= state.lastIndex -> state
        event.index > state.lastIndex + 1 -> state.copy(needsHistory = true)
        else -> applyEvent(state, event)
    }

    /** Drops the oldest whole turns until the conversation is small, keeping the newest; the computer can replay the rest. */
    fun trimForMemoryPressure(state: TranscriptState): TranscriptState {
        var current = state
        while (true) {
            val next = trimmed(current, PRESSURE_TRANSCRIPT_SIZE)
            if (next === current) return current
            current = next
        }
    }

    /**
     * Merges one history chunk. Events the state already holds are skipped by index, so a live event that raced
     * the request is not drawn twice. [isLast] clears [TranscriptState.needsHistory].
     */
    fun replay(
        state: TranscriptState,
        events: List<AgentStreamEvent>,
        isLast: Boolean,
        truncatedAtFront: Boolean,
    ): TranscriptState {
        val folded = events.fold(state) { accumulated, event ->
            if (event.index > accumulated.lastIndex) applyEvent(accumulated, event) else accumulated
        }
        return folded.copy(
            truncatedAtFront = folded.truncatedAtFront || truncatedAtFront,
            needsHistory = folded.needsHistory && !isLast,
        )
    }
}

private const val MAXIMUM_TRANSCRIPT_SIZE = 512 * 1024
private const val PRESSURE_TRANSCRIPT_SIZE = 64 * 1024

private fun applyEvent(state: TranscriptState, event: AgentStreamEvent): TranscriptState =
    trimmed(applyPayload(state, event.payload)).copy(lastIndex = event.index)

private fun applyPayload(state: TranscriptState, payload: AgentStreamPayload): TranscriptState = when (payload) {
    is AgentStreamPayload.SessionReady -> state
    is AgentStreamPayload.UserPrompt ->
        state.copy(openReplyID = null).appendRow { TranscriptRow.User(it, payload.text) }
    is AgentStreamPayload.TurnStarted -> state.copy(sessionState = AgentSessionState.WORKING)
    is AgentStreamPayload.TextDelta -> textDelta(state, payload.text)
    is AgentStreamPayload.TextFinal -> textFinal(state, payload.text)
    is AgentStreamPayload.ToolStarted -> toolStarted(state, payload)
    is AgentStreamPayload.ToolFinished -> toolFinished(state, payload)
    is AgentStreamPayload.ApprovalRequested -> approvalRequested(state, payload)
    is AgentStreamPayload.ApprovalResolved -> approvalResolved(state, payload)
    is AgentStreamPayload.TurnFinished -> turnFinished(state, payload.summary)
    is AgentStreamPayload.Notice -> state.appendRow { TranscriptRow.Notice(it, payload.text) }
    is AgentStreamPayload.Failure ->
        state.appendRow { TranscriptRow.Failure(it, payload.message) }.copy(sessionState = AgentSessionState.FAILED)
    is AgentStreamPayload.SessionExited -> state.copy(sessionState = AgentSessionState.EXITED)
    is AgentStreamPayload.Child -> child(state, payload.parentCallID, payload.event)
}

private fun textDelta(state: TranscriptState, text: String): TranscriptState {
    val working = state.copy(sessionState = AgentSessionState.WORKING)
    val open = state.openReply() ?: return working.copy(openReplyID = state.nextRowID)
        .appendRow { TranscriptRow.AssistantText(it, text) }
    val (index, reply) = open
    return working.replaceRow(index, reply.copy(text = reply.text + text)).addSize(text.length)
}

private fun textFinal(state: TranscriptState, text: String): TranscriptState {
    val closed = state.copy(openReplyID = null)
    val open = state.openReply() ?: return closed.appendRow { TranscriptRow.AssistantText(it, text) }
    val (index, reply) = open
    return closed.replaceRow(index, reply.copy(text = text)).addSize(text.length - reply.text.length)
}

private fun toolStarted(state: TranscriptState, payload: AgentStreamPayload.ToolStarted): TranscriptState {
    val plan = payload.call.plan
    val withPlan = if (plan.isNullOrEmpty()) state else upsertPlan(state, plan)
    return withPlan.copy(openReplyID = null, sessionState = AgentSessionState.WORKING)
        .appendRow { TranscriptRow.ToolCall(it, payload.call, ToolStatus.Running, null, truncated = false) }
}

private fun upsertPlan(state: TranscriptState, steps: List<AgentPlanStep>): TranscriptState {
    val index = state.rows.indexOfFirst { it is TranscriptRow.Plan }
    if (index < 0) return state.appendRow { TranscriptRow.Plan(it, steps) }
    val plan = state.rows[index] as TranscriptRow.Plan
    return state.replaceRow(index, plan.copy(steps = steps))
}

private fun toolFinished(state: TranscriptState, payload: AgentStreamPayload.ToolFinished): TranscriptState {
    val index = state.rows.indexOfFirst { it is TranscriptRow.ToolCall && it.call.id == payload.callID }
    val tool = state.rows.getOrNull(index) as? TranscriptRow.ToolCall ?: return state
    // A second finish (a background task's notice) carries no output and must not wipe the first one's.
    val finished = tool.copy(
        status = if (payload.ok) ToolStatus.Ok else ToolStatus.Failed,
        output = payload.output ?: tool.output,
        truncated = if (payload.output == null) tool.truncated else payload.truncated,
    )
    return state.replaceRow(index, finished)
        .updateSubagent(payload.callID) { it.copy(sessionState = AgentSessionState.IDLE) }
        .addSize(payload.output?.length ?: 0)
}

private fun approvalRequested(state: TranscriptState, payload: AgentStreamPayload.ApprovalRequested): TranscriptState {
    val awaiting = ToolStatus.AwaitingApproval(payload.approvalID)
    val index = state.rows.indexOfFirst { it is TranscriptRow.ToolCall && it.call.id == payload.call.id }
    val withTool = if (index >= 0) {
        val tool = state.rows[index] as TranscriptRow.ToolCall
        state.replaceRow(index, tool.copy(status = awaiting))
    } else {
        state.appendRow { TranscriptRow.ToolCall(it, payload.call, awaiting, null, truncated = false) }
    }
    return withTool.appendRow {
        TranscriptRow.Approval(it, payload.approvalID, payload.call, payload.reason, ApprovalStatus.Pending)
    }.copy(sessionState = AgentSessionState.AWAITING_APPROVAL)
}

private fun approvalResolved(state: TranscriptState, payload: AgentStreamPayload.ApprovalResolved): TranscriptState {
    val rows = state.rows.map { row ->
        when {
            row is TranscriptRow.Approval && row.approvalID == payload.approvalID ->
                row.copy(status = ApprovalStatus.Answered(payload.decision))
            row is TranscriptRow.ToolCall && row.status == ToolStatus.AwaitingApproval(payload.approvalID) ->
                // A chosen option is an allow with a payload, so only a deny stops the call.
                row.copy(status = if (payload.decision == AgentApprovalDecision.Deny) ToolStatus.Denied else ToolStatus.Running)
            else -> row
        }
    }
    val stillPending = rows.any { it is TranscriptRow.Approval && it.status == ApprovalStatus.Pending }
    val next = state.copy(rows = rows)
    return if (stillPending) next else next.copy(sessionState = AgentSessionState.WORKING)
}

private fun turnFinished(state: TranscriptState, summary: AgentTurnSummary): TranscriptState {
    // A finished turn cannot still be waiting: the CLI cancels the asks it held, and a bar that outlives its turn answers nothing.
    val rows = state.rows.map { row ->
        if (row is TranscriptRow.Approval && row.status == ApprovalStatus.Pending) row.copy(status = ApprovalStatus.Cancelled) else row
    }
    return state.copy(rows = rows, openReplyID = null, sessionState = AgentSessionState.IDLE)
        .appendRow { TranscriptRow.TurnSummary(it, summary) }
}

/** A sub-agent has no turns of its own: it works until the call that spawned it finishes. */
private fun child(state: TranscriptState, parentCallID: String, event: AgentStreamPayload): TranscriptState {
    val known = state.rows.any { it is TranscriptRow.Subagent && it.parentCallID == parentCallID }
    val withSubagent = if (known) state else state.appendRow { TranscriptRow.Subagent(it, parentCallID, TranscriptState()) }
    return withSubagent.updateSubagent(parentCallID) { applyPayload(it, event).copy(sessionState = AgentSessionState.WORKING) }
}

private fun trimmed(state: TranscriptState, limit: Int = MAXIMUM_TRANSCRIPT_SIZE): TranscriptState {
    if (state.approximateSize <= limit) return state
    val turnStarts = state.rows.indices.filter { state.rows[it] is TranscriptRow.User }
    if (turnStarts.size < 2) return state
    val rows = state.rows.drop(turnStarts[1])
    return state.copy(rows = rows, approximateSize = rows.sumOf(::sizeOf), truncatedAtFront = true)
}

private inline fun TranscriptState.appendRow(make: (Long) -> TranscriptRow): TranscriptState {
    val row = make(nextRowID)
    return copy(rows = rows + row, nextRowID = nextRowID + 1, approximateSize = approximateSize + sizeOf(row))
}

/** Replaces a row without touching [TranscriptState.approximateSize]; a caller that grows text adds the growth. */
private fun TranscriptState.replaceRow(index: Int, row: TranscriptRow): TranscriptState =
    copy(rows = rows.toMutableList().apply { set(index, row) })

private fun TranscriptState.addSize(characters: Int): TranscriptState = copy(approximateSize = approximateSize + characters)

private fun TranscriptState.openReply(): Pair<Int, TranscriptRow.AssistantText>? {
    val id = openReplyID ?: return null
    val index = rows.indexOfFirst { it.id == id }
    val reply = rows.getOrNull(index) as? TranscriptRow.AssistantText ?: return null
    return index to reply
}

private fun TranscriptState.updateSubagent(
    parentCallID: String,
    change: (TranscriptState) -> TranscriptState,
): TranscriptState = copy(
    rows = rows.map { row ->
        if (row is TranscriptRow.Subagent && row.parentCallID == parentCallID) {
            row.copy(transcript = change(row.transcript))
        } else {
            row
        }
    },
)

private fun sizeOf(row: TranscriptRow): Int = when (row) {
    is TranscriptRow.User -> row.text.length
    is TranscriptRow.AssistantText -> row.text.length
    is TranscriptRow.ToolCall ->
        (row.output?.length ?: 0) + (row.call.detail?.length ?: 0) + (row.call.diff?.length ?: 0)
    is TranscriptRow.Notice -> row.text.length
    is TranscriptRow.Failure -> row.message.length
    is TranscriptRow.Plan, is TranscriptRow.Subagent, is TranscriptRow.TurnSummary, is TranscriptRow.Approval -> 0
}

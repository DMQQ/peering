package pl.dmq.peering.session.notices

import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.TerminalAttentionKind

/**
 * Decides which notifications a connected phone shows while the app is out of sight, and when to take them back.
 * Feed it the current [NoticeInputs] after anything changes (null when no session is running); it returns what to
 * post and retract. A notice is posted once per time away: coming back retracts all of them, and whatever still waits
 * is announced again the next time the app is left.
 */
class BackgroundNotices {
    /** Each posted key with the chat it belongs to, if any. */
    private val posted = LinkedHashMap<String, String?>()
    private var chatStates: Map<String, ChatMemory> = emptyMap()

    private data class ChatMemory(val state: AgentSessionState, val loaded: Boolean)

    fun plan(inputs: NoticeInputs?): List<NoticeAction> {
        val previous = chatStates
        chatStates = inputs?.chats.orEmpty().associate { it.chatID to ChatMemory(it.state, it.loaded) }
        if (inputs == null || !inputs.away || !inputs.enabled) return retractAll()

        val stale = posted.keys.filterNot { stillTrue(it, posted.getValue(it), inputs) }.toSet()
        stale.forEach(posted::remove)

        val actions = mutableListOf<NoticeAction>()
        if (stale.isNotEmpty()) actions += NoticeAction.Retract(stale)
        for (notice in approvals(inputs) + finished(inputs, previous) + terminals(inputs)) {
            if (notice.key !in posted) {
                posted[notice.key] = notice.chatID
                actions += NoticeAction.Post(notice)
            }
        }
        return actions
    }

    private fun retractAll(): List<NoticeAction> {
        if (posted.isEmpty()) return emptyList()
        val keys = posted.keys.toSet()
        posted.clear()
        return listOf(NoticeAction.Retract(keys))
    }

    /** A chat that has not replayed its history is unknown, not empty: its notices stay until it says otherwise. */
    private fun stillTrue(key: String, chatID: String?, inputs: NoticeInputs): Boolean {
        val id = key.substringAfter(':')
        val chat = inputs.chats.firstOrNull { it.chatID == chatID }
        return when (key.substringBefore(':')) {
            APPROVAL -> chat != null && (!chat.loaded || chat.pending.any { it.approvalID == id })
            FINISHED -> chat != null && chat.state == AgentSessionState.IDLE
            TERMINAL -> inputs.terminals.any { it.id == id && it.attention != null }
            else -> false
        }
    }

    private fun approvals(inputs: NoticeInputs): List<Notice> = inputs.chats.filter { it.loaded }.flatMap { chat ->
        chat.pending.map { approval ->
            val notice = ApprovalNotice.of(chat.chatID, approval)
            Notice(
                key = "$APPROVAL:${approval.approvalID}",
                kind = if (notice.isQuestion) NoticeKind.QuestionAsked else NoticeKind.ApprovalNeeded,
                subject = chat.title,
                detail = notice.body.ifEmpty { null },
                hostName = inputs.hostName,
                hostID = inputs.hostID,
                chatID = chat.chatID,
                approval = notice,
            )
        }
    }

    /** Only a turn the phone watched end: a replay of history lands as state changes too, so an unloaded chat announces nothing. */
    private fun finished(inputs: NoticeInputs, previous: Map<String, ChatMemory>): List<Notice> =
        inputs.chats.filter { chat ->
            val before = previous[chat.chatID]
            chat.loaded && before != null && before.loaded &&
                before.state == AgentSessionState.WORKING && chat.state == AgentSessionState.IDLE
        }.map { chat ->
            Notice(
                key = "$FINISHED:${chat.chatID}",
                kind = NoticeKind.AgentFinished,
                subject = chat.title,
                detail = chat.lastReply?.let { ApprovalNotice.truncated(it) }?.ifEmpty { null },
                hostName = inputs.hostName,
                hostID = inputs.hostID,
                chatID = chat.chatID,
                approval = null,
            )
        }

    private fun terminals(inputs: NoticeInputs): List<Notice> = inputs.terminals.mapNotNull { terminal ->
        val kind = when (terminal.attention) {
            TerminalAttentionKind.PASSWORD -> NoticeKind.TerminalPassword
            TerminalAttentionKind.CONFIRMATION -> NoticeKind.TerminalConfirmation
            null -> return@mapNotNull null
        }
        Notice("$TERMINAL:${terminal.id}", kind, terminal.name, null, inputs.hostName, inputs.hostID, null, null)
    }

    private companion object {
        const val APPROVAL = "approval"
        const val FINISHED = "finished"
        const val TERMINAL = "terminal"
    }
}

package pl.dmq.peering.session.notices

import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.TerminalAttentionKind

enum class NoticeChannel { Approvals, Terminals, Agents }

/** What a notice says; the app maps each kind to its wording. */
enum class NoticeKind(val channel: NoticeChannel) {
    ApprovalNeeded(NoticeChannel.Approvals),
    QuestionAsked(NoticeChannel.Approvals),
    TerminalPassword(NoticeChannel.Terminals),
    TerminalConfirmation(NoticeChannel.Terminals),
    AgentFinished(NoticeChannel.Agents),
}

/**
 * One notification to show. [key] is stable for the thing it is about, so showing it again replaces it and retracting
 * it takes it back. [subject] is the chat's title or the shell's name; [detail] is the request or the reply, if any.
 */
data class Notice(
    val key: String,
    val kind: NoticeKind,
    val subject: String,
    val detail: String?,
    val hostName: String?,
    val hostID: String?,
    val chatID: String?,
    val approval: ApprovalNotice?,
)

sealed interface NoticeAction {
    data class Post(val notice: Notice) : NoticeAction

    data class Retract(val keys: Set<String>) : NoticeAction
}

/** An agent chat as the notices see it. A chat that is not [loaded] has not replayed its history, so its state is not news. */
data class ChatView(
    val chatID: String,
    val title: String,
    val state: AgentSessionState,
    val loaded: Boolean,
    val pending: List<PendingApproval>,
    val lastReply: String?,
)

data class TerminalView(val id: String, val name: String, val attention: TerminalAttentionKind?)

/** Everything the planner reads. [away] is true while no screen of the app is shown; [enabled] is the Settings toggle. */
data class NoticeInputs(
    val away: Boolean,
    val enabled: Boolean,
    val hostName: String?,
    val hostID: String?,
    val chats: List<ChatView>,
    val terminals: List<TerminalView>,
)

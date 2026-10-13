package pl.dmq.peering.background

import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import pl.dmq.peering.DebugLog
import pl.dmq.peering.R
import pl.dmq.peering.session.notices.ApprovalNotice
import pl.dmq.peering.session.notices.Notice
import pl.dmq.peering.session.notices.NoticeKind

/** Where the planner's decisions land. */
internal interface NoticeSink {
    fun post(notice: Notice)

    fun retract(keys: Set<String>)
}

/** Shows [Notice]s as notifications. A phone that has not allowed notifications shows none, and nothing else changes. */
internal class NoticePoster(private val context: Context) : NoticeSink {
    private val manager = NotificationManagerCompat.from(context)

    override fun post(notice: Notice) {
        if (!manager.areNotificationsEnabled()) return
        val builder = NotificationCompat.Builder(context, NoticeChannels.idOf(notice.kind.channel))
            .setSmallIcon(R.drawable.ic_widget_computer)
            .setContentTitle(title(notice))
            .setContentText(text(notice))
            .setStyle(NotificationCompat.BigTextStyle().bigText(text(notice)))
            .setSubText(notice.hostName.takeIf { notice.kind != NoticeKind.TerminalPassword && notice.kind != NoticeKind.TerminalConfirmation })
            .setContentIntent(open(notice))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(if (notice.kind == NoticeKind.AgentFinished) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_HIGH)
        notice.approval?.let { approval -> actions(notice.key, approval).forEach(builder::addAction) }
        try {
            manager.notify(notice.key, NOTICE_ID, builder.build())
        } catch (denied: SecurityException) {
            DebugLog.w("PeeringNotices", { "the notification permission was withdrawn before posting" }, denied)
        }
    }

    override fun retract(keys: Set<String>) {
        keys.forEach { manager.cancel(it, NOTICE_ID) }
    }

    private fun open(notice: Notice) = notice.chatID?.let { OpenIntents.chat(context, it, notice.hostID) }
        ?: OpenIntents.session(context, notice.hostID)

    private fun title(notice: Notice): String = when (notice.kind) {
        NoticeKind.TerminalPassword, NoticeKind.TerminalConfirmation -> context.getString(R.string.bg_terminal_needs_you)
        else -> notice.subject
    }

    private fun text(notice: Notice): String = when (notice.kind) {
        NoticeKind.ApprovalNeeded -> notice.detail ?: context.getString(R.string.bg_approval_needed_fallback)
        NoticeKind.QuestionAsked -> notice.detail ?: context.getString(R.string.bg_question_asked_fallback)
        NoticeKind.AgentFinished -> notice.detail ?: context.getString(R.string.bg_agent_finished)
        NoticeKind.TerminalPassword -> terminalText(notice, R.string.bg_terminal_password)
        NoticeKind.TerminalConfirmation -> terminalText(notice, R.string.bg_terminal_confirmation)
    }

    /** The computer's name leads, because two computers can both have a shell called prod. */
    private fun terminalText(notice: Notice, waiting: Int): String {
        val sentence = context.getString(waiting, notice.subject)
        return notice.hostName?.let { context.getString(R.string.bg_with_computer, it, sentence) } ?: sentence
    }

    private fun actions(key: String, approval: ApprovalNotice): List<NotificationCompat.Action> =
        approval.actions.map { action ->
            val title = when (val title = action.title) {
                ApprovalNotice.Title.Allow -> context.getString(R.string.bg_allow)
                ApprovalNotice.Title.Deny -> context.getString(R.string.bg_deny)
                is ApprovalNotice.Title.Label -> title.text
            }
            NotificationCompat.Action.Builder(0, title, NoticeActionReceiver.answerIntent(context, key, approval, action.id))
                .setAuthenticationRequired(action.requiresAuthentication)
                .build()
        }

    companion object {
        const val NOTICE_ID = 2
    }
}

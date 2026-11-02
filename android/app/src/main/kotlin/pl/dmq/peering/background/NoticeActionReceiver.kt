package pl.dmq.peering.background

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.core.app.NotificationManagerCompat
import pl.dmq.peering.PeeringApplication
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.notices.ApprovalNotice
import pl.dmq.peering.session.notices.Notice
import pl.dmq.peering.session.notices.NoticeKind
import pl.dmq.peering.session.notices.QuestionChain

/** Takes the buttons of the notifications: Disconnect on the session's, Allow, Deny and the answers on an approval's. */
class NoticeActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val wiring = (context.applicationContext as? PeeringApplication)?.wiring ?: return
        when (intent.action) {
            ACTION_DISCONNECT -> wiring.holder.end()
            ACTION_ANSWER -> answer(context, intent, wiring.holder.active.value?.controller?.agentChat)
        }
    }

    private fun answer(context: Context, intent: Intent, chat: AgentChat?) {
        val button = intent.getStringExtra(EXTRA_BUTTON).orEmpty()
        val chatID = intent.getStringExtra(EXTRA_CHAT_ID) ?: return
        val approvalID = intent.getStringExtra(EXTRA_APPROVAL_ID) ?: return
        val key = intent.getStringExtra(EXTRA_KEY) ?: return
        val chain = QuestionChain.decoded(intent.getStringExtra(EXTRA_CHAIN))
        val answer = if (chain == null) {
            ApprovalNotice.answerFor(button, intent.getStringArrayExtra(EXTRA_ANSWERS)?.toList().orEmpty())
        } else {
            when (val outcome = chain.after(button)) {
                is QuestionChain.Outcome.Answer -> outcome.answer
                is QuestionChain.Outcome.Next -> return askNext(context, intent, key, ApprovalNotice.stepOf(approvalID, chatID, outcome.chain))
                null -> null
            }
        } ?: return
        send(context, chat, key, chatID, approvalID, answer)
    }

    /** Replaces the answered question's notification with the next one, under the same key. */
    private fun askNext(context: Context, intent: Intent, key: String, next: ApprovalNotice) {
        val notice = Notice(
            key = key,
            kind = NoticeKind.QuestionAsked,
            subject = intent.getStringExtra(EXTRA_SUBJECT).orEmpty(),
            detail = next.body,
            hostName = intent.getStringExtra(EXTRA_HOST_NAME),
            hostID = intent.getStringExtra(EXTRA_HOST_ID),
            chatID = next.chatID,
            approval = next,
        )
        NoticePoster(context).post(notice)
    }

    private fun send(context: Context, chat: AgentChat?, key: String, chatID: String, approvalID: String, answer: ApprovalAnswer) {
        if (chat?.answer(chatID, approvalID, answer) == true) {
            NotificationManagerCompat.from(context).cancel(key, NoticePoster.NOTICE_ID)
        } else {
            Toast.makeText(context, R.string.bg_answer_failed, Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        private const val ACTION_DISCONNECT = "pl.dmq.peering.background.DISCONNECT"
        private const val ACTION_ANSWER = "pl.dmq.peering.background.ANSWER"
        private const val EXTRA_BUTTON = "button"
        private const val EXTRA_CHAT_ID = "chat_id"
        private const val EXTRA_APPROVAL_ID = "approval_id"
        private const val EXTRA_ANSWERS = "answers"
        private const val EXTRA_KEY = "key"
        private const val EXTRA_CHAIN = "chain"
        private const val EXTRA_SUBJECT = "subject"
        private const val EXTRA_HOST_NAME = "host_name"
        private const val EXTRA_HOST_ID = "host_id"

        fun disconnectIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION_DISCONNECT).setClass(context, NoticeActionReceiver::class.java)
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        /** One intent per button: the data keeps the buttons of different asks from sharing a PendingIntent. */
        fun answerIntent(context: Context, notice: Notice, approval: ApprovalNotice, button: String): PendingIntent {
            val key = notice.key
            val step = approval.chain?.step ?: 0
            val intent = Intent(ACTION_ANSWER)
                .setClass(context, NoticeActionReceiver::class.java)
                .setData(Uri.parse("peering-notice://answer/${Uri.encode(approval.approvalID)}/$step/$button"))
                .putExtra(EXTRA_CHAIN, approval.chain?.encoded())
                .putExtra(EXTRA_SUBJECT, notice.subject)
                .putExtra(EXTRA_HOST_NAME, notice.hostName)
                .putExtra(EXTRA_HOST_ID, notice.hostID)
                .putExtra(EXTRA_BUTTON, button)
                .putExtra(EXTRA_CHAT_ID, approval.chatID)
                .putExtra(EXTRA_APPROVAL_ID, approval.approvalID)
                .putExtra(EXTRA_ANSWERS, approval.answers.toTypedArray())
                .putExtra(EXTRA_KEY, key)
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }
}

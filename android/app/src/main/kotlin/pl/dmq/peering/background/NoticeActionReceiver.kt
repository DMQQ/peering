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
import pl.dmq.peering.session.notices.ApprovalNotice

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
        val answers = intent.getStringArrayExtra(EXTRA_ANSWERS)?.toList().orEmpty()
        val answer = ApprovalNotice.answerFor(intent.getStringExtra(EXTRA_BUTTON).orEmpty(), answers) ?: return
        val chatID = intent.getStringExtra(EXTRA_CHAT_ID) ?: return
        val approvalID = intent.getStringExtra(EXTRA_APPROVAL_ID) ?: return
        val key = intent.getStringExtra(EXTRA_KEY) ?: return
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

        fun disconnectIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION_DISCONNECT).setClass(context, NoticeActionReceiver::class.java)
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        /** One intent per button: the data keeps the buttons of different asks from sharing a PendingIntent. */
        fun answerIntent(context: Context, key: String, approval: ApprovalNotice, button: String): PendingIntent {
            val intent = Intent(ACTION_ANSWER)
                .setClass(context, NoticeActionReceiver::class.java)
                .setData(Uri.parse("peering-notice://answer/${Uri.encode(approval.approvalID)}/$button"))
                .putExtra(EXTRA_BUTTON, button)
                .putExtra(EXTRA_CHAT_ID, approval.chatID)
                .putExtra(EXTRA_APPROVAL_ID, approval.approvalID)
                .putExtra(EXTRA_ANSWERS, approval.answers.toTypedArray())
                .putExtra(EXTRA_KEY, key)
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }
}

package pl.dmq.peering.background

import android.app.Notification
import android.content.Context
import androidx.core.app.NotificationCompat
import pl.dmq.peering.R
import pl.dmq.peering.session.notices.ProgressNotice
import pl.dmq.peering.session.notices.ProgressStage

/** The ongoing notification for an agent turn in flight, on the quiet session channel so an update never makes a sound. */
internal object AgentProgressNotification {
    fun build(context: Context, notice: ProgressNotice): Notification {
        val working = notice.stage == ProgressStage.WORKING
        val text = context.getString(if (working) R.string.bg_progress_working else R.string.bg_progress_awaiting_approval)
        return NotificationCompat.Builder(context, NoticeChannels.SESSION)
            .setSmallIcon(R.drawable.ic_widget_computer)
            .setContentTitle(notice.title)
            .setContentText(text)
            .setSubText(notice.hostName)
            .setContentIntent(OpenIntents.chat(context, notice.chatID, notice.hostID))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setProgress(0, 0, working)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setTimeoutAfter(STALE_AFTER_MS)
            .build()
    }

    /** A backstop for a notification whose process died: a turn quiet this long is gone, and each update restarts it. */
    private const val STALE_AFTER_MS = 2L * 60 * 60 * 1000
}

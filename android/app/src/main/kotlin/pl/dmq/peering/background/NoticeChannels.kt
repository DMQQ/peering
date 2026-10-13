package pl.dmq.peering.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import pl.dmq.peering.R
import pl.dmq.peering.session.notices.NoticeChannel

/** The notification channels, named so the system settings can tell them apart. Creating one that exists changes nothing. */
internal object NoticeChannels {
    const val SESSION = "session"

    fun idOf(channel: NoticeChannel): String = when (channel) {
        NoticeChannel.Approvals -> "approvals"
        NoticeChannel.Terminals -> "terminals"
        NoticeChannel.Agents -> "agents"
    }

    fun ensure(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannels(
            listOf(
                channel(context, SESSION, R.string.bg_channel_session, R.string.bg_channel_session_description, NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
                channel(context, idOf(NoticeChannel.Approvals), R.string.bg_channel_approvals, R.string.bg_channel_approvals_description, NotificationManager.IMPORTANCE_HIGH),
                channel(context, idOf(NoticeChannel.Terminals), R.string.bg_channel_terminals, R.string.bg_channel_terminals_description, NotificationManager.IMPORTANCE_HIGH),
                channel(context, idOf(NoticeChannel.Agents), R.string.bg_channel_agents, R.string.bg_channel_agents_description, NotificationManager.IMPORTANCE_DEFAULT),
            ),
        )
    }

    private fun channel(context: Context, id: String, name: Int, description: Int, importance: Int) =
        NotificationChannel(id, context.getString(name), importance).apply { this.description = context.getString(description) }
}

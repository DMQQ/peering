package pl.dmq.peering.background

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import pl.dmq.peering.DebugLog
import pl.dmq.peering.R
import pl.dmq.peering.session.notices.KeepAliveStatus

/**
 * Holds the process while a session is open and shows the ongoing notification. It does nothing else: the session
 * lives in the app's scope, and the service only keeps Android from stopping the process behind it.
 */
class SessionKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val status = intent?.getStringExtra(EXTRA_STATUS)?.let { name -> KeepAliveStatus.entries.firstOrNull { it.name == name } }
        if (intent == null || status == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        NoticeChannels.ensure(this)
        val notification = notification(this, status, intent.getStringExtra(EXTRA_HOST_NAME), intent.getStringExtra(EXTRA_HOST_ID))
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        return START_NOT_STICKY
    }

    companion object {
        private const val EXTRA_STATUS = "status"
        private const val EXTRA_HOST_NAME = "host_name"
        private const val EXTRA_HOST_ID = "host_id"
        private const val NOTIFICATION_ID = 1
        private const val TAG = "PeeringKeepAlive"

        /**
         * Starts the service or updates its notification. Android refuses to start one from the background; the session
         * then simply lives as it did before the service existed. False when it did not start.
         */
        fun run(context: Context, status: KeepAliveStatus, hostName: String?, hostId: String?): Boolean {
            val intent = Intent(context, SessionKeepAliveService::class.java)
                .putExtra(EXTRA_STATUS, status.name)
                .putExtra(EXTRA_HOST_NAME, hostName)
                .putExtra(EXTRA_HOST_ID, hostId)
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (refused: IllegalStateException) {
                DebugLog.w(TAG, { "the keep-alive service could not start" }, refused)
                false
            } catch (refused: SecurityException) {
                DebugLog.w(TAG, { "the keep-alive service was not allowed to start" }, refused)
                false
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SessionKeepAliveService::class.java))
        }

        private fun notification(context: Context, status: KeepAliveStatus, hostName: String?, hostId: String?): Notification {
            val name = hostName ?: context.getString(R.string.bg_session_this_computer)
            val title = when (status) {
                KeepAliveStatus.Connecting -> context.getString(R.string.bg_session_connecting, name)
                KeepAliveStatus.Connected -> context.getString(R.string.bg_session_connected, name)
                KeepAliveStatus.Reconnecting -> context.getString(R.string.bg_session_reconnecting, name)
            }
            return NotificationCompat.Builder(context, NoticeChannels.SESSION)
                .setSmallIcon(R.drawable.ic_widget_computer)
                .setContentTitle(title)
                .setContentText(context.getString(R.string.bg_session_detail))
                .setContentIntent(OpenIntents.session(context, hostId))
                .addAction(0, context.getString(R.string.bg_disconnect), NoticeActionReceiver.disconnectIntent(context))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }
    }
}

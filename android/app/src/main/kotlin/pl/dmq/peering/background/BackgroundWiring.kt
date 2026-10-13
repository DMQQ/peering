package pl.dmq.peering.background

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import pl.dmq.peering.feature.settings.DevicePreferences
import pl.dmq.peering.session.notices.KeepAliveStatus
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.processForeground

/** Starts the background story for the process: the service while a session is open, and the notices while it is out of sight. */
internal class BackgroundWiring(
    context: Context,
    scope: CoroutineScope,
    preferences: SharedPreferences,
    active: Flow<ActiveSession?>,
    devicePrefs: DevicePreferences,
) {
    val permission = NotificationPermission(context, preferences)

    init {
        NoticeChannels.ensure(context)
        BackgroundCoordinator(
            live = liveSessions(active),
            prefs = devicePrefs.prefs,
            away = processForeground().map { !it },
            keepAlive = ServiceHost(context),
            sink = NoticePoster(context),
            onSessionStarted = permission::onSessionStarted,
        ).start(scope)
    }

    private class ServiceHost(private val context: Context) : KeepAliveHost {
        override fun run(status: KeepAliveStatus, hostName: String?, hostId: String?) =
            SessionKeepAliveService.run(context, status, hostName, hostId)

        override fun stop() = SessionKeepAliveService.stop(context)
    }
}

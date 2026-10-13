package pl.dmq.peering.background

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.notices.BackgroundNotices
import pl.dmq.peering.session.notices.KeepAlivePolicy
import pl.dmq.peering.session.notices.KeepAliveStatus
import pl.dmq.peering.session.notices.NoticeAction
import pl.dmq.peering.session.notices.NoticeInputs
import pl.dmq.peering.session.notices.NoticeSources

/** The foreground service, as far as the coordinator needs it. */
internal interface KeepAliveHost {
    /** Starts the service or refreshes its notification. False when Android refused. */
    fun run(status: KeepAliveStatus, hostName: String?, hostId: String?): Boolean

    fun stop()
}

/**
 * Joins the session, the settings and whether the app is on screen into the two things the background story does: keep
 * the process alive behind the ongoing notification, and post or retract the notices the planner decides on.
 */
internal class BackgroundCoordinator(
    private val live: Flow<LiveSession?>,
    private val prefs: Flow<DevicePrefs>,
    private val away: Flow<Boolean>,
    private val keepAlive: KeepAliveHost,
    private val sink: NoticeSink,
    private val onSessionStarted: (notificationsEnabled: Boolean) -> Unit,
) {
    private val notices = BackgroundNotices()
    private var running: Triple<KeepAliveStatus, String?, String?>? = null
    private var hostName: String? = null
    private var hadSession = false
    private var refused = false

    fun start(scope: CoroutineScope) {
        scope.launch {
            combine(live, prefs, away) { session, prefs, away -> Triple(session, prefs, away) }
                .collect { (session, prefs, away) -> apply(session, prefs, away) }
        }
    }

    internal fun apply(session: LiveSession?, prefs: DevicePrefs, away: Boolean) {
        noteSession(session, prefs)
        syncKeepAlive(session, prefs, away)
        val inputs = session?.takeIf { away && prefs.notifies }?.let { inputs(it, away = true) }
        for (action in notices.plan(inputs)) {
            when (action) {
                is NoticeAction.Post -> sink.post(action.notice)
                is NoticeAction.Retract -> sink.retract(action.keys)
            }
        }
    }

    private fun noteSession(session: LiveSession?, prefs: DevicePrefs) {
        val phase = session?.phase
        if (phase is SessionPhase.Ready) hostName = phase.hostName
        if (session == null) hostName = null
        if (session != null && !hadSession) onSessionStarted(prefs.notifies)
        hadSession = session != null
    }

    /** A refusal is retried once the app is on screen, where Android allows a start. */
    private fun syncKeepAlive(session: LiveSession?, prefs: DevicePrefs, away: Boolean) {
        if (refused && !away) {
            refused = false
            running = null
        }
        val status = KeepAlivePolicy.statusFor(prefs.keepsSessionInBackground, session?.phase)
        val wanted = status?.let { Triple(it, hostName, session?.hostId) }
        if (wanted == running) return
        running = wanted
        if (wanted == null) {
            keepAlive.stop()
        } else {
            refused = !keepAlive.run(wanted.first, wanted.second, wanted.third)
        }
    }

    private fun inputs(session: LiveSession, away: Boolean) = NoticeInputs(
        away = away,
        enabled = true,
        hostName = hostName,
        hostID = session.hostId,
        chats = NoticeSources.chats(session.chats),
        terminals = NoticeSources.terminals(session.terminals),
    )
}

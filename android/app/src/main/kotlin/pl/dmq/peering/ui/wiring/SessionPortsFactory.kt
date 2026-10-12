package pl.dmq.peering.ui.wiring

import android.os.Build
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.SessionFactory
import pl.dmq.peering.platform.net.OkHttpSignalling
import pl.dmq.peering.platform.net.UdpLane
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.controller.DownloadWriter
import pl.dmq.peering.session.controller.RelayPorts
import pl.dmq.peering.session.controller.SessionController
import pl.dmq.peering.session.controller.SessionPorts
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.ports.VideoSink

/** Builds a session controller over the platform objects of the app graph, for one target. */
internal class SessionPortsFactory(
    private val sessions: SessionFactory,
    private val picture: VideoSink,
    private val history: SessionHistory,
) {
    fun open(target: ConnectTarget, scope: CoroutineScope): ActiveSession {
        val lane = if (target is ConnectTarget.Relay) UdpLane.bind() else null
        val relay = lane?.let { RelayPorts(RelaySignallingLink(OkHttpSignalling()), it) }
        val ports = SessionPorts(
            identity = sessions.identity,
            clientName = Build.MODEL.orEmpty(),
            pins = sessions.pins,
            random = sessions.random,
            clock = sessions.clock,
            control = ControlSockets(sessions.tls),
            discovery = sessions.discovery,
            sink = picture,
            downloads = DownloadWriter { _, _ -> throw UnsupportedOperationException(DOWNLOADS_NOT_STORED) },
            relay = relay,
        )
        return ActiveSession(target, SessionController(scope, target, ports, history), lane)
    }

    private companion object {
        const val DOWNLOADS_NOT_STORED = "downloads are not stored yet"
    }
}

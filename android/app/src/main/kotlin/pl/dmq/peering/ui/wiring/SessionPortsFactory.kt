package pl.dmq.peering.ui.wiring

import pl.dmq.peering.DebugLog
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.SessionFactory
import pl.dmq.peering.platform.net.UdpLane
import pl.dmq.peering.platform.net.followMoves
import pl.dmq.peering.platform.video.codecSupport
import pl.dmq.peering.billing.Billing
import pl.dmq.peering.session.clipboard.ClipboardHistory
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.controller.QualitySource
import pl.dmq.peering.session.controller.RelayPorts
import pl.dmq.peering.session.controller.SessionController
import pl.dmq.peering.session.controller.SessionPorts
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.hosts.RememberedLanAddresses
import pl.dmq.peering.session.ports.VideoSink

/** Builds a session controller over the platform objects of the app graph, for one target. */
internal class SessionPortsFactory(
    private val sessions: SessionFactory,
    private val picture: VideoSink,
    private val history: SessionHistory,
    private val quality: QualitySource,
    private val billing: Billing,
    private val lanAddresses: RememberedLanAddresses,
    private val clipboardHistory: ClipboardHistory,
    private val deviceName: () -> String,
) : SessionOpener {
    override fun open(target: ConnectTarget, scope: CoroutineScope): ActiveSession {
        val lane = if (target.mayUseRelay()) UdpLane.bind() else null
        val relay = lane?.let { RelayPorts(sessions.newRelaySignalling(), it, billing::entitlement) }
        val downloads = SessionDownloads()
        val ports = SessionPorts(
            identity = sessions.identity,
            clientName = deviceName(),
            pins = sessions.pins,
            random = sessions.random,
            clock = sessions.clock,
            control = ControlSockets(sessions.tls),
            discovery = sessions.discovery,
            sink = picture,
            downloads = downloads,
            relay = relay,
            quality = quality,
            videoCodecs = codecSupport(),
            log = { message -> DebugLog.d(TAG) { message } },
            lanReached = lanAddresses::remember,
            clipboardHistory = clipboardHistory,
        )
        val controller = SessionController(scope, target, ports, history)
        val networkWatch = sessions.networkChanges.followMoves(scope, controller::networkChanged)
        return ActiveSession(target, controller, lane, downloads, networkWatch)
    }
}

private const val TAG = "PeeringSession"

private fun ConnectTarget.mayUseRelay(): Boolean = this is ConnectTarget.Relay || (this is ConnectTarget.Paired && relayAllowed)

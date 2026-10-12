package pl.dmq.peering.session.controller

import pl.dmq.peering.session.clipboard.ClipboardHistory
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.DeviceIdentity
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.session.ports.SessionLog
import pl.dmq.peering.session.ports.VideoSink

/**
 * Everything a [SessionController] reaches outside itself. [relay] is needed only for relay targets, and [discovery] only
 * for pairing, since a QR code names a host but not where it is. [videoCodecs] are the codecs this device decodes, best first; null
 * declares none, which the host reads as both. [lanReached] hears the address of each host a session
 * opened to on the local network, so the next dial can start there before discovery has answered.
 * [clipboardHistory] outlives a session when the owner passes the same one to each.
 */
class SessionPorts(
    val identity: DeviceIdentity,
    val clientName: String,
    val pins: PinStore,
    val random: Random,
    val clock: Clock,
    val control: ControlConnector,
    val discovery: Discovery,
    val sink: VideoSink,
    val downloads: DownloadWriter,
    val relay: RelayPorts? = null,
    val quality: QualitySource = QualitySource.Default,
    val videoCodecs: List<String>? = null,
    val log: SessionLog = SessionLog.None,
    val lanReached: (hostId: String, address: PeerAddress) -> Unit = { _, _ -> },
    val clipboardHistory: ClipboardHistory = ClipboardHistory(),
)

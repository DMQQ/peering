package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.DeviceIdentity
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.session.ports.VideoSink

/**
 * Everything a [SessionController] reaches outside itself. [relay] is needed only for relay targets, and [discovery] only
 * for pairing, since a QR code names a host but not where it is. [videoCodecs] are the codecs this device decodes, best first; null
 * declares none, which the host reads as both.
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
)

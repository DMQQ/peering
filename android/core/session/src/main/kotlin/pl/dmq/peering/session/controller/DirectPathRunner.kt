package pl.dmq.peering.session.controller

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.DirectPathProber
import pl.dmq.peering.session.relay.ProbeAction
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.VIDEO_TOKEN_SIZE
import kotlin.time.Duration.Companion.seconds

/**
 * Runs a [DirectPathProber] for one relayed link: it asks the relay where the Mac is and sends sealed probes there. The
 * probing is advisory, since a session that finds no direct path stays on the relay, so a failed ask only means no
 * address this time.
 */
internal class DirectPathRunner(
    private val lanes: VideoLanes,
    private val datagrams: DatagramTransport,
    private val relay: RelayConnect,
    private val videoToken: ByteArray,
) {
    val prober = DirectPathProber()

    suspend fun tick(now: Double) {
        for (action in prober.tick(now)) perform(action)
    }

    /** A datagram from an address other than the relay's. If it authenticates, that address is the Mac's direct one. */
    fun onForeignDatagram(source: PeerAddress, bytes: ByteArray) {
        if (lanes.onDirectDatagram(bytes)) prober.onAuthenticatedDatagram(source)
    }

    private suspend fun perform(action: ProbeAction) {
        when (action) {
            ProbeAction.AskRelay -> askRelay()
            is ProbeAction.SendProbe -> sendProbe(action.address)
            is ProbeAction.Report -> Unit
        }
    }

    private suspend fun askRelay() {
        val address = try {
            withTimeoutOrNull(ASK_TIMEOUT) { relay.discoverPeer(videoToken, attempts = 1) }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Exception) {
            null
        }
        if (address == null) {
            prober.onPeerAddressUnknown()
        } else {
            prober.onPeerAddress(address.host, address.port)
        }
    }

    /** The relay token comes off: a direct peer reads the first bytes of a datagram as the counter. */
    private suspend fun sendProbe(address: PeerAddress) {
        for (sealed in lanes.seal(MessageKind.DirectProbe, ByteArray(0))) {
            datagrams.send(sealed.copyOfRange(VIDEO_TOKEN_SIZE, sealed.size), address)
        }
    }

    private companion object {
        val ASK_TIMEOUT = 2.seconds
    }
}

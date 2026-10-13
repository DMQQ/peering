package pl.dmq.peering.ui.wiring

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread
import pl.dmq.peering.DebugLog
import pl.dmq.peering.session.wake.WakeOnLan

/** Sends the wake packets as UDP broadcasts. Nothing answers a magic packet, so a send that fails is only logged. */
internal object WakeBroadcast {
    /** Sends a packet for each readable address in [addresses] and returns how many there were. The sending happens off the calling thread. */
    fun send(addresses: List<String>): Int {
        val packets = addresses.mapNotNull(WakeOnLan::magicPacket)
        if (packets.isEmpty()) return 0
        thread(name = "wake-on-lan", isDaemon = true) {
            try {
                DatagramSocket().use { socket ->
                    socket.broadcast = true
                    val broadcast = InetAddress.getByName(BROADCAST)
                    for (packet in packets) for (port in WakeOnLan.PORTS) socket.send(DatagramPacket(packet, packet.size, broadcast, port))
                }
            } catch (failure: java.io.IOException) {
                DebugLog.w(TAG, { "the wake packet could not be sent" }, failure)
            }
        }
        return packets.size
    }

    private const val BROADCAST = "255.255.255.255"
    private const val TAG = "PeeringWake"
}

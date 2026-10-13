package pl.dmq.peering.platform.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.ReceivedDatagram

private const val MAX_DATAGRAM = 65_535
private const val RECEIVE_POLL_MS = 500

/**
 * One unconnected socket on one local port, sending to the relay and to the direct peer alike. The receive loop polls
 * with a timeout because a blocking receive cannot be interrupted by cancelling the collector.
 */
class UdpLane private constructor(private val socket: DatagramSocket) : DatagramTransport {
    val localPort: Int get() = socket.localPort

    override suspend fun send(bytes: ByteArray, destination: PeerAddress) {
        withContext(Dispatchers.IO) {
            val address = InetAddress.getByName(destination.host)
            socket.send(DatagramPacket(bytes, bytes.size, address, destination.port))
        }
    }

    override val received: Flow<ReceivedDatagram> = flow {
        val buffer = ByteArray(MAX_DATAGRAM)
        val packet = DatagramPacket(buffer, buffer.size)
        while (currentCoroutineContext().isActive) {
            packet.length = buffer.size
            try {
                socket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (failure: SocketException) {
                if (socket.isClosed) break else throw failure
            }
            val source = PeerAddress(packet.address.hostAddress.orEmpty(), packet.port)
            emit(ReceivedDatagram(source, buffer.copyOf(packet.length)))
        }
    }.flowOn(Dispatchers.IO)

    /** Closes the socket; [received] completes. */
    fun close() {
        socket.close()
    }

    companion object {
        /** Binds the lane to [localPort], or to any free port when it is 0. */
        fun bind(localPort: Int = 0): UdpLane {
            val socket = DatagramSocket(localPort)
            socket.soTimeout = RECEIVE_POLL_MS
            return UdpLane(socket)
        }
    }
}

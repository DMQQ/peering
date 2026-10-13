package pl.dmq.peering.platform.net

import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import pl.dmq.peering.session.ports.ControlTransport

private const val READ_SIZE = 16 * 1024

/** Blocking socket I/O moved onto the IO dispatcher; the session layer sees suspending calls and a flow. */
class TlsControlTransport internal constructor(
    private val socket: SSLSocket,
    private val trust: PinningTrustManager,
) : ControlTransport {
    private val writeLock = Mutex()
    private val closed = AtomicBoolean(false)

    override suspend fun send(bytes: ByteArray) {
        withContext(Dispatchers.IO) {
            writeLock.withLock {
                socket.outputStream.apply {
                    write(bytes)
                    flush()
                }
            }
        }
    }

    override val received: Flow<ByteArray> = flow {
        val buffer = ByteArray(READ_SIZE)
        val input = socket.inputStream
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            emit(buffer.copyOf(count))
        }
    }.flowOn(Dispatchers.IO).catch { failure -> if (!closed.get()) throw failure }

    override fun close() {
        if (closed.compareAndSet(false, true)) socket.close()
    }

    override fun peerPublicKey(): ByteArray? = trust.observedKey()
}

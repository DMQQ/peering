package pl.dmq.peering.platform.net

import java.io.Closeable
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Closes a socket on a thread of its own. Closing a TLS socket writes the goodbye alert, which Android refuses on the main
 * thread with a NetworkOnMainThreadException, and the session's coroutines run there.
 */
internal object SocketCloser {
    private val threads = Executors.newCachedThreadPool { task -> Thread(task, "socket-closer").apply { isDaemon = true } }

    fun close(socket: Closeable) {
        threads.execute {
            try {
                socket.close()
            } catch (ignored: IOException) {
                // The peer is gone or the socket already closed: the close was the point, not its result.
            }
        }
    }
}

package pl.dmq.peering.platform.net

import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

/**
 * One relay connection per instance: [connect] once, then exchange messages until the socket ends. Once the socket
 * ends, [receive] throws, so the session layer reconnects rather than waiting forever.
 */
class OkHttpSignalling(
    private val client: OkHttpClient = OkHttpClient(),
    private val url: String = DEFAULT_URL,
) : Signalling {
    private val inbound = Channel<String>(Channel.UNLIMITED)
    private val opened = CompletableDeferred<Unit>()

    @Volatile
    private var socket: WebSocket? = null

    /** Opens the WebSocket and returns once it is open. Throws when the relay refuses or cannot be reached. */
    suspend fun connect() {
        socket = client.newWebSocket(Request.Builder().url(url).build(), Listener())
        opened.await()
    }

    override suspend fun send(message: RelayClientMessage) {
        val open = socket ?: throw IOException("relay connection is not open")
        if (!open.send(message.toJson())) throw IOException("relay connection is closed")
    }

    override suspend fun receive(): RelayServerMessage {
        while (true) {
            val text = inbound.receive()
            val message = RelayServerMessage.parse(text)
            if (message !is RelayServerMessage.Unknown) return message
        }
    }

    /** Starts a normal close; [receive] throws once the relay has answered. */
    fun close() {
        socket?.close(NORMAL_CLOSE, null)
    }

    /** Drops the connection at once without the closing handshake. */
    fun cancel() {
        socket?.cancel()
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            inbound.trySend(text)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            endWith(IOException("relay closed the connection: $code $reason"))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            endWith(IOException("relay connection failed", t))
        }

        private fun endWith(failure: IOException) {
            opened.completeExceptionally(failure)
            inbound.close(failure)
        }
    }

    companion object {
        const val DEFAULT_URL = "wss://getpeering.app/"
        const val KEEP_ALIVE_INTERVAL_MS = 25_000L
        private const val NORMAL_CLOSE = 1000

        /** The frame that keeps the relay connection from idling out, sent every [KEEP_ALIVE_INTERVAL_MS]. */
        fun keepAliveFrame(): String = RelayClientMessage.Ping.toJson()
    }
}

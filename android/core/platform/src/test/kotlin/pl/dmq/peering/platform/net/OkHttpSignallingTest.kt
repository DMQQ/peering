package pl.dmq.peering.platform.net

import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

class OkHttpSignallingTest {
    private lateinit var server: MockWebServer
    private val serverReceived = LinkedBlockingQueue<String>()

    @Before
    fun startServer() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun stopServer() {
        server.shutdown()
    }

    private fun enqueueRelay(onOpen: (WebSocket) -> Unit = {}, onClosing: (WebSocket) -> Unit = {}) {
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = onOpen(webSocket)

            override fun onMessage(webSocket: WebSocket, text: String) {
                serverReceived.add(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                onClosing(webSocket)
            }
        }))
    }

    private fun signalling() = OkHttpSignalling(url = server.url("/").toString())

    private fun <T> bounded(block: suspend () -> T): T = runBlocking { withTimeout(TimeUnit.SECONDS.toMillis(5)) { block() } }

    @Test
    fun sendWritesTheJsonFrameToTheRelay() {
        enqueueRelay()
        val signalling = signalling()
        bounded { signalling.connect() }

        bounded { signalling.send(RelayClientMessage.HostPresence("ABC")) }

        assertEquals("{\"hostId\":\"ABC\",\"type\":\"hostPresence\"}", serverReceived.poll(5, TimeUnit.SECONDS))
        signalling.cancel()
    }

    @Test
    fun receiveParsesTheNextRelayMessage() {
        enqueueRelay(onOpen = { it.send("{\"type\":\"pong\"}") })
        val signalling = signalling()
        bounded { signalling.connect() }

        assertEquals(RelayServerMessage.Pong, bounded { signalling.receive() })
        signalling.cancel()
    }

    @Test
    fun unknownMessageTypesAreSkipped() {
        enqueueRelay(onOpen = {
            it.send("{\"type\":\"someFutureMessage\",\"x\":1}")
            it.send("{\"type\":\"pong\"}")
        })
        val signalling = signalling()
        bounded { signalling.connect() }

        assertEquals(RelayServerMessage.Pong, bounded { signalling.receive() })
        signalling.cancel()
    }

    @Test
    fun closingTheSocketWakesAPendingReceive() {
        enqueueRelay(onClosing = { it.close(1000, null) })
        val signalling = signalling()
        bounded { signalling.connect() }

        val pending = runBlocking {
            withTimeout(TimeUnit.SECONDS.toMillis(5)) {
                val waiting = async { runCatching { signalling.receive() } }
                signalling.close()
                waiting.await()
            }
        }

        assertTrue(pending.exceptionOrNull() is IOException)
    }

    @Test
    fun sendFailsOnceTheRelayIsGone() {
        enqueueRelay()
        val signalling = signalling()
        bounded { signalling.connect() }
        signalling.cancel()

        assertThrows(IOException::class.java) {
            bounded { signalling.send(RelayClientMessage.Ping) }
        }
    }

    @Test
    fun keepAliveFrameIsThePingMessage() {
        assertEquals("{\"type\":\"ping\"}", OkHttpSignalling.keepAliveFrame())
    }

    @Test
    fun keepAliveIntervalIsTwentyFiveSeconds() {
        assertEquals(25_000L, OkHttpSignalling.KEEP_ALIVE_INTERVAL_MS)
    }
}

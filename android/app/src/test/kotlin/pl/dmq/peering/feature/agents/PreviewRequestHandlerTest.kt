package pl.dmq.peering.feature.agents

import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.preview.PreviewFetch
import pl.dmq.peering.feature.agents.preview.PreviewReply
import pl.dmq.peering.feature.agents.preview.PreviewRequestHandler
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewHeader
import pl.dmq.peering.wire.PreviewProxyEvent
import pl.dmq.peering.wire.toBase64

class PreviewRequestHandlerTest {
    private data class Asked(val port: Int, val method: String, val target: String, val headers: List<PreviewHeader>)

    private val asked = mutableListOf<Asked>()
    private val pageFailures = mutableListOf<PreviewFailure>()
    private val answers = ArrayDeque<List<PreviewProxyEvent>>()
    private val scope = CoroutineScope(Job() + Dispatchers.Unconfined)

    private val fetch: PreviewFetch = { port, method, target, headers ->
        asked += Asked(port, method, target, headers)
        flowOf(*answers.removeFirst().toTypedArray())
    }

    private val handler = PreviewRequestHandler(fetch, scope) { pageFailures += it }

    private fun ok(body: String, type: String = "text/html; charset=utf-8") = listOf(
        PreviewProxyEvent.Head(1, 200, listOf(PreviewHeader("Content-Type", type), PreviewHeader("ETag", "x"))),
        PreviewProxyEvent.Body(1, body.toByteArray().toBase64()),
        PreviewProxyEvent.End(1),
    )

    private fun handle(url: String, method: String = "GET", main: Boolean = true, headers: Map<String, String> = emptyMap()) =
        handler.handle(url, method, headers, main)

    @Test
    fun aPageOnTheComputersLoopbackIsFetchedAndStreamedBack() {
        answers += ok("<h1>hi</h1>")
        val reply = handle("http://localhost:3000/a?b=1", headers = mapOf("Accept" to "text/html", "Host" to "x"))!!
        assertEquals(Asked(3000, "GET", "/a?b=1", listOf(PreviewHeader("Accept", "text/html"))), asked.single())
        assertEquals(200, reply.status)
        assertEquals("text/html", reply.mimeType)
        assertEquals("utf-8", reply.charset)
        assertEquals("x", reply.headers["ETag"])
        assertEquals("<h1>hi</h1>", reply.body.readBytes().decodeToString())
    }

    @Test
    fun conditionalHeadersAreNeverSentSoTheComputerNeverAnswersNotModified() {
        answers += ok("a")
        handle("http://localhost:3000/", headers = mapOf("If-None-Match" to "x", "if-modified-since" to "y", "Accept" to "*/*"))
        assertEquals(listOf(PreviewHeader("Accept", "*/*")), asked.single().headers)
    }

    @Test
    fun aRequestForAnotherHostIsRefusedInsteadOfReachingThePhonesNetwork() {
        assertEquals(403, handle("https://cdn.example.com/lib.js", main = false)!!.status)
        assertEquals(403, handle("http://192.168.1.5/x", main = false)!!.status)
        assertTrue(asked.isEmpty())
        assertTrue(pageFailures.isEmpty())
    }

    @Test
    fun aSchemeThatCannotLeaveTheWebViewIsLeftAlone() {
        assertNull(handle("data:text/plain,hi", main = false))
        assertNull(handle("about:blank"))
    }

    @Test
    fun theWebViewIsNeverLeftToDialThePhonesOwnLoopback() {
        for (url in listOf("http://localhost/", "http://localhost:51515/", "http://127.0.0.1/x", "http://[::1]:3000/")) {
            val reply = handle(url, main = false)!!
            assertEquals(url, 403, reply.status)
        }
        assertTrue(asked.isEmpty())
        assertTrue(pageFailures.isEmpty())
    }

    @Test
    fun requestsThatSendDataAreAnsweredAsNotCarriedRatherThanSentWithoutTheirBody() {
        val reply = handle("http://localhost:3000/api", method = "POST", main = false)!!
        assertEquals(501, reply.status)
        assertTrue(asked.isEmpty())
    }

    @Test
    fun aRedirectInsideAPageSubresourceIsFollowedHere() {
        answers += listOf(PreviewProxyEvent.Head(1, 302, listOf(PreviewHeader("Location", "/real.js"))), PreviewProxyEvent.End(1))
        answers += ok("code", "text/javascript")
        val reply = handle("http://localhost:3000/old.js", main = false)!!
        assertEquals(listOf("/old.js", "/real.js"), asked.map { it.target })
        assertEquals("code", reply.body.readBytes().decodeToString())
    }

    @Test
    fun aRedirectOfThePageItselfMovesTheWebViewsAddress() {
        answers += listOf(PreviewProxyEvent.Head(1, 301, listOf(PreviewHeader("Location", "http://127.0.0.1:3000/home"))), PreviewProxyEvent.End(1))
        val reply = handle("http://localhost:3000/")!!
        val page = reply.body.readBytes().decodeToString()
        assertTrue(page, page.contains("location.replace(\"http://localhost:3000/home\")"))
        assertEquals(1, asked.size)
    }

    @Test
    fun aRedirectOutOfTheLoopbackIsRefusedAndReportedForThePage() {
        answers += listOf(PreviewProxyEvent.Head(1, 302, listOf(PreviewHeader("Location", "https://example.com/"))), PreviewProxyEvent.End(1))
        val reply = handle("http://localhost:3000/")!!
        assertEquals(403, reply.status)
        assertEquals(listOf(PreviewFailure.NOT_ALLOWED), pageFailures)
    }

    @Test
    fun aFailureOfThePageIsReportedButOneOfAFileIsNot() {
        answers += listOf(PreviewProxyEvent.Failure(1, PreviewFailure.NOT_LISTENING))
        assertEquals(502, handle("http://localhost:3000/")!!.status)
        assertEquals(listOf(PreviewFailure.NOT_LISTENING), pageFailures)
        answers += listOf(PreviewProxyEvent.Failure(2, PreviewFailure.TIMED_OUT))
        assertEquals(504, handle("http://localhost:3000/slow.js", main = false)!!.status)
        assertEquals(1, pageFailures.size)
    }

    @Test
    fun aBodyThatEndsInAFailureBreaksTheReadInsteadOfEndingShort() {
        answers += listOf(
            PreviewProxyEvent.Head(1, 200, listOf(PreviewHeader("Content-Type", "image/png"))),
            PreviewProxyEvent.Body(1, byteArrayOf(1, 2).toBase64()),
            PreviewProxyEvent.Failure(1, PreviewFailure.DISCONNECTED),
        )
        val body = handle("http://localhost:3000/a.png", main = false)!!.body
        assertEquals(1, body.read())
        assertEquals(2, body.read())
        assertThrows(IOException::class.java) { body.read() }
    }

    @Test
    fun aThreeHundredStatusWithNoRedirectIsPassedOnAsOkBecauseAWebViewRefusesIt() {
        val reply = PreviewReply.from(304, emptyList(), java.io.ByteArrayInputStream(ByteArray(0)))
        assertEquals(200, reply.status)
        assertEquals(502, PreviewReply.from(42, emptyList(), java.io.ByteArrayInputStream(ByteArray(0))).status)
    }

    @Test
    fun aReplyWithoutATypeIsBinaryAndRepeatedHeadersAreJoined() {
        val reply = PreviewReply.from(
            200,
            listOf(PreviewHeader("Vary", "Accept"), PreviewHeader("vary", "Origin"), PreviewHeader("Content-Length", "9")),
            java.io.ByteArrayInputStream(ByteArray(0)),
        )
        assertEquals("application/octet-stream", reply.mimeType)
        assertEquals(mapOf("Vary" to "Accept, Origin"), reply.headers)
    }

    @Test
    fun closingTheBodyStopsTheTransfer() {
        var cancelled = false
        val fetchForever: PreviewFetch = { _, _, _, _ ->
            flow {
                emit(PreviewProxyEvent.Head(1, 200))
                try {
                    kotlinx.coroutines.awaitCancellation()
                } finally {
                    cancelled = true
                }
            }
        }
        val reply = PreviewRequestHandler(fetchForever, scope) { }.handle("http://localhost:3000/", "GET", emptyMap(), true)!!
        reply.body.close()
        assertTrue(cancelled)
    }

    @Test
    fun aComputerThatNeverAnswersEndsInDisconnectedInsteadOfBlocking() {
        val silent: PreviewFetch = { _, _, _, _ -> flow { kotlinx.coroutines.awaitCancellation() } }
        val quick = PreviewRequestHandler(silent, scope, firstByteTimeoutMillis = 50, chunkTimeoutMillis = 50) { pageFailures += it }
        assertEquals(503, quick.handle("http://localhost:3000/", "GET", emptyMap(), true)!!.status)
        assertEquals(listOf(PreviewFailure.DISCONNECTED), pageFailures)
    }

    @Test
    fun aBodyThatStallsBreaksTheReadInsteadOfBlocking() {
        val stalls: PreviewFetch = { _, _, _, _ ->
            flow {
                emit(PreviewProxyEvent.Head(1, 200))
                emit(PreviewProxyEvent.Body(1, byteArrayOf(7).toBase64()))
                kotlinx.coroutines.awaitCancellation()
            }
        }
        val quick = PreviewRequestHandler(stalls, scope, firstByteTimeoutMillis = 1000, chunkTimeoutMillis = 50) { }
        val body = quick.handle("http://localhost:3000/a.bin", "GET", emptyMap(), false)!!.body
        assertEquals(7, body.read())
        assertThrows(IOException::class.java) { body.read() }
    }
}

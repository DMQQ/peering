package pl.dmq.peering.session.preview

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewHeader
import pl.dmq.peering.wire.PreviewProxyCommand
import pl.dmq.peering.wire.PreviewProxyEvent

class PreviewProxyClientTest {
    private val sent = mutableListOf<PreviewProxyCommand>()
    private var linked = true
    private val client = PreviewProxyClient { command ->
        if (linked) sent += command
        linked
    }

    private fun fetched() = sent.filterIsInstance<PreviewProxyCommand.Fetch>().map { it.request }

    @Test
    fun anAnswerIsHandedBackInPiecesUntilItsEnd() = runTest(UnconfinedTestDispatcher()) {
        val events = mutableListOf<PreviewProxyEvent>()
        val job = launch { client.fetch(3000, "GET", "/", listOf(PreviewHeader("Accept", "*/*"))).toList(events) }
        val id = fetched().single().id
        client.onEvent(PreviewProxyEvent.Head(id, 200))
        client.onEvent(PreviewProxyEvent.Body(id, "aGk="))
        client.onEvent(PreviewProxyEvent.End(id))
        job.join()
        assertEquals(listOf("Head", "Body", "End"), events.map { it::class.simpleName })
        assertTrue(sent.none { it is PreviewProxyCommand.Cancel })
    }

    @Test
    fun aResponseOverTheCapIsEndedAsTooLargeAndTheComputerIsToldToStop() = runTest(UnconfinedTestDispatcher()) {
        val capped = PreviewProxyClient(maxResponseBytes = 5) { command ->
            sent += command
            true
        }
        val events = mutableListOf<PreviewProxyEvent>()
        val job = launch { capped.fetch(3000, "GET", "/big").toList(events) }
        val id = fetched().single().id

        capped.onEvent(PreviewProxyEvent.Head(id, 200))
        capped.onEvent(PreviewProxyEvent.Body(id, "aGk="))
        capped.onEvent(PreviewProxyEvent.Body(id, "aGk="))
        job.join()

        assertEquals(PreviewProxyEvent.Failure(id, PreviewFailure.TOO_LARGE), events.last())
        assertEquals(3, events.size)
        assertTrue(sent.last() is PreviewProxyCommand.Cancel)
    }

    @Test
    fun eachRequestGetsItsOwnIdAndOnlyItsOwnEvents() = runTest(UnconfinedTestDispatcher()) {
        val first = mutableListOf<PreviewProxyEvent>()
        val second = mutableListOf<PreviewProxyEvent>()
        val a = launch { client.fetch(3000, "GET", "/a").toList(first) }
        val b = launch { client.fetch(3000, "GET", "/b").toList(second) }
        val (idA, idB) = fetched().map { it.id }
        client.onEvent(PreviewProxyEvent.End(idB))
        client.onEvent(PreviewProxyEvent.End(idA))
        a.join()
        b.join()
        assertEquals(listOf(PreviewProxyEvent.End(idA)), first)
        assertEquals(listOf(PreviewProxyEvent.End(idB)), second)
        assertTrue(idA != idB)
    }

    @Test
    fun stoppingEarlyTellsTheComputerToStop() = runTest(UnconfinedTestDispatcher()) {
        val job = launch { client.fetch(3000, "GET", "/big").toList() }
        val id = fetched().single().id
        client.onEvent(PreviewProxyEvent.Head(id, 200))
        job.cancel()
        job.join()
        assertEquals(PreviewProxyCommand.Cancel(id), sent.last())
    }

    @Test
    fun aRequestThatWasRefusedIsNeverSent() = runTest {
        val blocked = client.fetch(PreviewPolicy.HOST_PORT, "GET", "/").toList()
        assertEquals(listOf<PreviewProxyEvent>(PreviewProxyEvent.Failure(0, PreviewFailure.NOT_ALLOWED)), blocked)
        val badTarget = client.fetch(3000, "GET", "//evil.example/").toList()
        assertEquals(PreviewFailure.INVALID_REQUEST, (badTarget.single() as PreviewProxyEvent.Failure).reason)
        val oversize = client.fetch(3000, "POST", "/", body = ByteArray(PreviewPolicy.MAX_REQUEST_BODY_BYTES + 1)).toList()
        assertEquals(PreviewFailure.TOO_LARGE, (oversize.single() as PreviewProxyEvent.Failure).reason)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun withNoLinkTheRequestFailsAsDisconnected() = runTest {
        linked = false
        val events = client.fetch(3000, "GET", "/").toList()
        assertEquals(PreviewFailure.DISCONNECTED, (events.single() as PreviewProxyEvent.Failure).reason)
    }

    @Test
    fun losingTheLinkEndsEveryOpenRequest() = runTest(UnconfinedTestDispatcher()) {
        val one = mutableListOf<PreviewProxyEvent>()
        val two = mutableListOf<PreviewProxyEvent>()
        val a = launch { client.fetch(3000, "GET", "/a").toList(one) }
        val b = launch { client.fetch(3001, "GET", "/b").toList(two) }
        client.failAll()
        a.join()
        b.join()
        assertEquals(PreviewFailure.DISCONNECTED, (one.single() as PreviewProxyEvent.Failure).reason)
        assertEquals(PreviewFailure.DISCONNECTED, (two.single() as PreviewProxyEvent.Failure).reason)
        assertTrue(sent.none { it is PreviewProxyCommand.Cancel })
    }

    @Test
    fun anEventForARequestNobodyIsWaitingOnIsDropped() {
        client.onEvent(PreviewProxyEvent.Body(99, "aGk="))
        client.onEvent(PreviewProxyEvent.End(99))
        assertTrue(sent.isEmpty())
    }
}

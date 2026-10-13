package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewProxyTest {
    @Test
    fun aFetchCommandIsWrittenAsSwiftWritesTheCase() {
        val command = PreviewProxyCommand.Fetch(
            PreviewProxyRequest(7, 3000, "GET", "/a?b=1", listOf(PreviewHeader("Accept", "text/html"))),
        )
        val expected = """{"fetch":{"_0":{"id":7,"port":3000,"method":"GET","target":"/a?b=1","headers":[{"name":"Accept","value":"text/html"}]}}}"""
        assertTrue(command.toJson(), jsonEquals(command.toJson(), expected))
    }

    @Test
    fun aRequestBodyTravelsAsBase64() {
        val body = byteArrayOf(1, 2, 3).toBase64()
        val json = PreviewProxyCommand.Fetch(PreviewProxyRequest(1, 8080, "PUT", "/x", body = body)).toJson()
        assertTrue(json, json.contains("\"body\":\"AQID\""))
    }

    @Test
    fun aCancelCommandNamesTheRequest() {
        assertTrue(jsonEquals(PreviewProxyCommand.Cancel(9).toJson(), """{"cancel":{"id":9}}"""))
    }

    @Test
    fun everyEventCaseDecodes() {
        val head = PreviewProxyEvent.parse("""{"head":{"id":4,"status":200,"headers":[{"name":"content-type","value":"text/html"}]}}""")
        assertEquals(PreviewProxyEvent.Head(4, 200, listOf(PreviewHeader("content-type", "text/html"))), head)
        val body = PreviewProxyEvent.parse("""{"body":{"id":4,"data":"aGk="}}""") as PreviewProxyEvent.Body
        assertEquals("hi", body.bytes.decodeToString())
        assertEquals(PreviewProxyEvent.End(4, true), PreviewProxyEvent.parse("""{"end":{"id":4,"truncated":true}}"""))
        assertEquals(
            PreviewProxyEvent.Failure(4, PreviewFailure.NOT_LISTENING),
            PreviewProxyEvent.parse("""{"failure":{"id":4,"reason":"notListening"}}"""),
        )
    }

    @Test
    fun onlyAnEndOrAFailureIsFinal() {
        assertFalse(PreviewProxyEvent.Head(1, 200).isFinal)
        assertFalse(PreviewProxyEvent.Body(1, "").isFinal)
        assertTrue(PreviewProxyEvent.End(1).isFinal)
        assertTrue(PreviewProxyEvent.Failure(1, PreviewFailure.BUSY).isFinal)
    }

    @Test
    fun everyFailureReasonDecodes() {
        val reasons = listOf("invalidRequest", "notAllowed", "notListening", "timedOut", "tooLarge", "busy", "disconnected", "failed")
        val decoded = reasons.map { (PreviewProxyEvent.parse("""{"failure":{"id":1,"reason":"$it"}}""") as PreviewProxyEvent.Failure).reason }
        assertEquals(PreviewFailure.entries, decoded)
    }
}

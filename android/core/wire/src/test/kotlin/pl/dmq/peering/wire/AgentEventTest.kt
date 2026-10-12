package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentEventTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"
    private val session = """{"id":"$sessionID","agentID":"claude","title":"t","directory":"/","state":"idle","lastIndex":3,"createdAt":1.5}"""

    private val cases: List<Pair<String, AgentEvent>> = listOf(
        """{"snapshot":{"_0":[$session]}}""" to AgentEvent.Snapshot(listOf(WireJson.decodeFromString(session))),
        """{"snapshot":{"_0":[]}}""" to AgentEvent.Snapshot(emptyList()),
        """{"created":{"_0":$session}}""" to AgentEvent.Created(WireJson.decodeFromString(session)),
        """{"stream":{"sessionID":"$sessionID","event":{"index":1,"payload":{"turnStarted":{}}}}}""" to
            AgentEvent.Stream(sessionID, AgentStreamEvent(1, AgentStreamPayload.TurnStarted)),
        """{"replay":{"sessionID":"$sessionID","events":[{"index":1,"payload":{"userPrompt":{"text":"hi"}}}],"isLast":true,"truncatedAtFront":false}}""" to
            AgentEvent.Replay(sessionID, listOf(AgentStreamEvent(1, AgentStreamPayload.UserPrompt("hi"))), isLast = true, truncatedAtFront = false),
        """{"directory":{"path":"/Users/me","entries":[],"truncated":false}}""" to
            AgentEvent.Directory("/Users/me", emptyList(), truncated = false),
        """{"browseFailure":{"path":"/root","message":"Denied"}}""" to AgentEvent.BrowseFailure("/root", "Denied"),
        """{"browseWaiting":{"path":"/Desktop","message":"Waiting for permission"}}""" to
            AgentEvent.BrowseWaiting("/Desktop", "Waiting for permission"),
        """{"closed":{"sessionID":"$sessionID"}}""" to AgentEvent.Closed(sessionID),
        """{"modelChanged":{"sessionID":"$sessionID","model":"opus"}}""" to AgentEvent.ModelChanged(sessionID, "opus"),
        """{"modelChanged":{"sessionID":"$sessionID"}}""" to AgentEvent.ModelChanged(sessionID, null),
        """{"permissionModeChanged":{"sessionID":"$sessionID","mode":"plan"}}""" to
            AgentEvent.PermissionModeChanged(sessionID, AgentPermissionMode.PLAN),
        """{"usageChanged":{"sessionID":"$sessionID","usage":{"inputTokens":5,"cachedTokens":0,"outputTokens":9,"limits":[]}}}""" to
            AgentEvent.UsageChanged(sessionID, AgentUsage(inputTokens = 5, cachedTokens = 0, outputTokens = 9, limits = emptyList())),
        """{"failed":{"message":"No Mac answered"}}""" to AgentEvent.Failed(null, "No Mac answered"),
        """{"failed":{"sessionID":"$sessionID","message":"Process crashed"}}""" to AgentEvent.Failed(sessionID, "Process crashed"),
        """{"resumable":{"_0":[{"agentID":"claude","cliSessionID":"c0ffee","title":"Refactor"}]}}""" to
            AgentEvent.Resumable(listOf(WireJson.parseToJsonElement("""{"agentID":"claude","cliSessionID":"c0ffee","title":"Refactor"}"""))),
        """{"resumable":{"_0":[]}}""" to AgentEvent.Resumable(emptyList()),
    )

    @Test
    fun everyEventCaseDecodesAndEncodesBackToItsShape() {
        for ((json, event) in cases) {
            assertEquals(event, AgentEvent.parse(json))
            assertTrue("$json vs ${event.toJson()}", jsonEquals(event.toJson(), json))
        }
    }

    @Test
    fun aReplaySkipsAnEventWhoseCaseItDoesNotKnowAndKeepsTheRest() {
        val replay = AgentEvent.parse(
            """{"replay":{"sessionID":"$sessionID","events":[{"index":1,"payload":{"userPrompt":{"text":"hi"}}},{"index":2,"payload":{"futureCase":{}}},{"index":3,"payload":{"turnStarted":{}}}],"isLast":true,"truncatedAtFront":false}}""",
        )

        val events = (replay as AgentEvent.Replay).events
        assertEquals(listOf(1L, 3L), events.map { it.index })
    }

    @Test
    fun unknownEventCaseIsASerializationException() {
        assertThrows(kotlinx.serialization.SerializationException::class.java) { AgentEvent.parse("""{"teleport":{}}""") }
    }

    @Test
    fun unknownEventCaseThrows() {
        assertThrows(SwiftEnumException::class.java) { AgentEvent.parse("""{"teleport":{}}""") }
    }

    @Test
    fun everyStreamPayloadCaseRoundTrips() {
        val payloads = listOf(
            """{"sessionReady":{"agentID":"claude","cliSessionID":"abc","model":"opus","directory":"/app"}}""",
            """{"sessionReady":{"agentID":"codex","directory":"/app"}}""",
            """{"userPrompt":{"text":"hello"}}""",
            """{"textDelta":{"text":"Hi"}}""",
            """{"textFinal":{"text":"Hi there"}}""",
            """{"toolStarted":{"call":{"id":"t1","name":"Bash","title":"Run","detail":"ls"}}}""",
            """{"toolFinished":{"callID":"t1","ok":true,"output":"done","truncated":false}}""",
            """{"toolFinished":{"callID":"t1","ok":false,"truncated":true}}""",
            """{"approvalRequested":{"approvalID":"ap1","call":{"id":"t1","name":"Bash","title":"Run"},"reason":"needs approval"}}""",
            """{"approvalResolved":{"approvalID":"ap1","decision":{"deny":{}}}}""",
            """{"turnFinished":{"summary":{"ok":true,"stopped":false}}}""",
            """{"notice":{"text":"Resumed"}}""",
            """{"failure":{"message":"boom"}}""",
            """{"sessionExited":{"status":0}}""",
            """{"child":{"parentCallID":"t9","event":{"textDelta":{"text":"sub"}}}}""",
        )
        for (json in payloads) {
            val payload = WireJson.decodeFromString<AgentStreamPayload>(json)
            assertTrue(json, jsonEquals(WireJson.encodeToString(AgentStreamPayload.serializer(), payload), json))
        }
    }

    @Test
    fun unknownStreamPayloadCaseThrows() {
        assertThrows(SwiftEnumException::class.java) {
            WireJson.decodeFromString<AgentStreamPayload>("""{"somethingNew":{}}""")
        }
    }
}

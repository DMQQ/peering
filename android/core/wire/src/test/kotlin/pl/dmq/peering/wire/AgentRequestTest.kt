package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentRequestTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"

    private val cases: List<Pair<AgentRequest, String>> = listOf(
        AgentRequest.ListSessions to """{"list":{}}""",
        AgentRequest.History(sessionID, 4) to """{"history":{"sessionID":"$sessionID","since":4}}""",
        AgentRequest.Start("claude", "/Users/me/app") to """{"start":{"agentID":"claude","directory":"/Users/me/app"}}""",
        AgentRequest.Start("claude") to """{"start":{"agentID":"claude"}}""",
        AgentRequest.Prompt(sessionID, "fix the bug") to """{"prompt":{"sessionID":"$sessionID","text":"fix the bug"}}""",
        AgentRequest.Approval(sessionID, "ap1", AgentApprovalDecision.Allow) to
            """{"approval":{"sessionID":"$sessionID","approvalID":"ap1","decision":{"allow":{}}}}""",
        AgentRequest.Approval(sessionID, "ap2", AgentApprovalDecision.Choose(listOf("Postgres"))) to
            """{"approval":{"sessionID":"$sessionID","approvalID":"ap2","decision":{"choose":{"_0":["Postgres"]}}}}""",
        AgentRequest.Interrupt(sessionID) to """{"interrupt":{"sessionID":"$sessionID"}}""",
        AgentRequest.SetModel(sessionID, "sonnet") to """{"setModel":{"sessionID":"$sessionID","model":"sonnet"}}""",
        AgentRequest.SetModel(sessionID) to """{"setModel":{"sessionID":"$sessionID"}}""",
        AgentRequest.SetPermissionMode(sessionID, AgentPermissionMode.ACCEPT_EDITS) to
            """{"setPermissionMode":{"sessionID":"$sessionID","mode":"acceptEdits"}}""",
        AgentRequest.Close(sessionID) to """{"close":{"sessionID":"$sessionID"}}""",
        AgentRequest.Browse("/Users/me") to """{"browse":{"path":"/Users/me"}}""",
        AgentRequest.Browse() to """{"browse":{}}""",
        AgentRequest.Changes(sessionID) to """{"changes":{"sessionID":"$sessionID"}}""",
        AgentRequest.Commit(sessionID, listOf("src/a.rs", "README.md"), "Add a") to
            """{"commit":{"sessionID":"$sessionID","paths":["src/a.rs","README.md"],"message":"Add a"}}""",
        AgentRequest.Push(sessionID) to """{"push":{"sessionID":"$sessionID"}}""",
        AgentRequest.ListResumable to """{"listResumable":{}}""",
        AgentRequest.Resume("claude", "c0ffee") to """{"resume":{"agentID":"claude","cliSessionID":"c0ffee"}}""",
        AgentRequest.Pause(sessionID) to """{"pause":{"sessionID":"$sessionID"}}""",
    )

    @Test
    fun everyRequestEncodesToItsSwiftShape() {
        for ((request, json) in cases) {
            assertTrue("$json vs ${request.toJson()}", jsonEquals(request.toJson(), json))
        }
    }

    @Test
    fun everyRequestShapeDecodesToItsCase() {
        for ((request, json) in cases) {
            assertEquals(request, AgentRequest.parse(json))
        }
    }

    @Test
    fun unknownRequestCaseThrows() {
        assertThrows(SwiftEnumException::class.java) { AgentRequest.parse("""{"teleport":{}}""") }
    }
}

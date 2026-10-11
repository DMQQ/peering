package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentWireTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"

    private val fullSession = """
        {"id":"$sessionID","agentID":"claude","title":"Claude Code","directory":"/Users/me/app","state":"awaitingApproval",
        "lastIndex":12,"model":"opus","permissionMode":"plan","permissionModes":["manual","acceptEdits","plan","auto"],
        "modelChoices":["opus","sonnet"],"usage":{"contextUsedTokens":84000,"contextWindowTokens":1000000,"inputTokens":16000,
        "cachedTokens":41000,"outputTokens":900,"costUSD":0.07,"limits":[{"label":"5 hours","usedFraction":0.07,"resetsAt":812979000.0}]},
        "createdAt":0.0}
    """.trimIndent().replace("\n", "")

    @Test
    fun sessionListingWithEveryOptionalFieldRoundTrips() {
        val info = WireJson.decodeFromString<AgentSessionInfo>(fullSession)
        assertEquals(AgentSessionState.AWAITING_APPROVAL, info.state)
        assertEquals(AgentPermissionMode.PLAN, info.permissionMode)
        assertEquals(0.07, info.usage!!.costUSD!!, 0.0)
        assertTrue(jsonEquals(WireJson.encodeToString(AgentSessionInfo.serializer(), info), fullSession))
    }

    @Test
    fun listingFromOlderMacDecodesWithOptionalFieldsEmpty() {
        val older = """{"id":"$sessionID","agentID":"codex","title":"Codex","directory":"/tmp","state":"idle","lastIndex":0,"createdAt":0}"""
        val info = WireJson.decodeFromString<AgentSessionInfo>(older)
        assertEquals("codex", info.agentID)
        assertNull(info.usage)
        assertNull(info.permissionMode)
        assertNull(info.permissionModes)
    }

    @Test
    fun unknownSessionStateFailsTheDecode() {
        val text = fullSession.replace("awaitingApproval", "sleeping")
        val failed = runCatching { WireJson.decodeFromString<AgentSessionInfo>(text) }.isFailure
        assertTrue(failed)
    }

    @Test
    fun usageLimitsWithoutResetDateDecode() {
        val text = """{"label":"30 days","usedFraction":1.0}"""
        assertEquals(AgentUsageLimit("30 days", 1.0), WireJson.decodeFromString<AgentUsageLimit>(text))
    }

    @Test
    fun approvalDecisionsUseTheSwiftCaseShapes() {
        assertDecision(AgentApprovalDecision.Allow, """{"allow":{}}""")
        assertDecision(AgentApprovalDecision.Deny, """{"deny":{}}""")
        assertDecision(AgentApprovalDecision.Choose(listOf("Postgres", "Yes")), """{"choose":{"_0":["Postgres","Yes"]}}""")
    }

    @Test
    fun toolCallWithQuestionsAndPlanRoundTrips() {
        val question = """{"id":"t1","name":"AskUserQuestion","title":"Ask","detail":"Which database?","questions":[{"header":"Store","question":"Which database?","options":[{"label":"Postgres","detail":"Relational"},{"label":"SQLite"}]}]}"""
        val plan = """{"id":"t2","name":"TodoWrite","title":"Plan","plan":[{"text":"Read the code","status":"completed"},{"text":"Write the test","status":"inProgress"},{"text":"Ship","status":"pending"}]}"""
        for (text in listOf(question, plan)) {
            assertTrue(jsonEquals(WireJson.encodeToString(AgentToolCall.serializer(), WireJson.decodeFromString<AgentToolCall>(text)), text))
        }
    }

    @Test
    fun planStatusSpellingsMapToOneState() {
        assertEquals(AgentPlanStepStatus.IN_PROGRESS, AgentPlanStepStatus.fromRaw("in_progress"))
        assertEquals(AgentPlanStepStatus.IN_PROGRESS, AgentPlanStepStatus.fromRaw("inProgress"))
        assertEquals(AgentPlanStepStatus.COMPLETED, AgentPlanStepStatus.fromRaw("done"))
        assertEquals(AgentPlanStepStatus.PENDING, AgentPlanStepStatus.fromRaw("something else"))
        assertEquals(AgentPlanStepStatus.PENDING, AgentPlanStepStatus.fromRaw(null))
    }

    @Test
    fun turnSummaryKeepsOnlyWhatTheCliReported() {
        val text = """{"ok":false,"stopped":true,"costUSD":0.25,"inputTokens":10,"outputTokens":20,"duration":3.5,"model":"sonnet"}"""
        assertTrue(jsonEquals(WireJson.encodeToString(AgentTurnSummary.serializer(), WireJson.decodeFromString<AgentTurnSummary>(text)), text))
        val bare = WireJson.decodeFromString<AgentTurnSummary>("""{"ok":true,"stopped":false}""")
        assertNull(bare.costUSD)
    }

    private fun assertDecision(decision: AgentApprovalDecision, json: String) {
        assertEquals(decision, WireJson.decodeFromString(AgentApprovalDecisionSerializer, json))
        assertTrue(jsonEquals(WireJson.encodeToString(AgentApprovalDecisionSerializer, decision), json))
    }
}

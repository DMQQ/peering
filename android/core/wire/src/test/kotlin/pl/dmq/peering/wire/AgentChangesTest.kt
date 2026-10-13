package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class AgentChangesTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"

    @Test
    fun aReportFromTheComputerDecodesWithItsBranchAndFiles() {
        val json = """{"changes":{"sessionID":"$sessionID","report":{"isRepository":true,"files":[
            {"path":"a/b.swift","kind":"modified","added":3,"removed":1,"diff":"@@ -1 +1 @@"},
            {"path":"c.png","kind":"untracked","added":0,"removed":0}],
            "paths":["a/b.swift","c.png","d.txt"],"truncated":false,
            "branch":{"head":"main","upstream":"origin/main","remote":"origin","mergeRef":"refs/heads/main","ahead":2,"behind":0}}}}"""
        val report = (AgentEvent.parse(json) as AgentEvent.Changes).decoded()!!
        assertEquals(listOf("a/b.swift", "c.png"), report.files.map { it.path })
        assertEquals(AgentChangeKind.UNTRACKED, report.files[1].kind)
        assertNull(report.files[1].diff)
        assertEquals(2, report.branch?.ahead)
        assertEquals("origin/main", report.branch?.upstream)
    }

    @Test
    fun aFailureReportCarriesOnlyItsMessage() {
        val json = """{"changes":{"sessionID":"$sessionID","report":{"isRepository":false,"files":[],"paths":[],"truncated":false,"message":"Not a git folder"}}}"""
        val report = (AgentEvent.parse(json) as AgentEvent.Changes).decoded()!!
        assertFalse(report.isRepository)
        assertEquals("Not a git folder", report.message)
    }

    @Test
    fun aDetachedHeadHasNoBranchName() {
        val json = """{"changes":{"sessionID":"$sessionID","report":{"isRepository":true,"files":[],"paths":[],"truncated":false,"branch":{"ahead":0,"behind":0}}}}"""
        val report = (AgentEvent.parse(json) as AgentEvent.Changes).decoded()!!
        assertNull(report.branch?.head)
    }

    @Test
    fun anUnreadableReportDecodesToNullInsteadOfThrowing() {
        val json = """{"changes":{"sessionID":"$sessionID","report":{"files":"nope"}}}"""
        assertNull((AgentEvent.parse(json) as AgentEvent.Changes).decoded())
    }

    @Test
    fun aGitResultDecodes() {
        val json = """{"gitResult":{"sessionID":"$sessionID","result":{"operation":"push","succeeded":false,"message":"rejected"}}}"""
        val result = (AgentEvent.parse(json) as AgentEvent.GitResult).decoded()
        assertNotNull(result)
        assertEquals(AgentGitOperation.PUSH, result!!.operation)
        assertFalse(result.succeeded)
    }
}

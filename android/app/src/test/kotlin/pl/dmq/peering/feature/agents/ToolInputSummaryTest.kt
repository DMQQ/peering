package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.AgentToolCall

class ToolInputSummaryTest {
    private fun call(name: String, title: String = name, detail: String? = null, filePath: String? = null) =
        AgentToolCall(id = "c", name = name, title = title, detail = detail, filePath = filePath)

    @Test
    fun aBashCommandIsTheCommandItself() {
        val summary = ToolInputSummary.of(call("Bash", title = "Run command", detail = "git push --force"))
        assertEquals(ToolInputKind.COMMAND, summary.kind)
        assertEquals("git push --force", summary.primary)
        assertEquals(ApprovalRisk.RUNS_COMMAND, summary.risk)
    }

    @Test
    fun aCommandWithNoDetailFallsBackToItsTitle() {
        assertEquals("Run command", ToolInputSummary.of(call("bash", title = "Run command", detail = "  ")).primary)
    }

    @Test
    fun anEditShowsTheFilePathNotTheDiff() {
        val summary = ToolInputSummary.of(call("Edit", detail = "@@ -1 +1 @@", filePath = "/Users/me/app/Main.kt"))
        assertEquals(ToolInputKind.FILE_CHANGE, summary.kind)
        assertEquals("/Users/me/app/Main.kt", summary.primary)
        assertEquals(ApprovalRisk.CHANGES_FILES, summary.risk)
    }

    @Test
    fun aWriteWithoutAPathFallsBackToItsDetail() {
        assertEquals("notes.md", ToolInputSummary.of(call("Write", detail = "notes.md")).primary)
    }

    @Test
    fun aReadIsReadRiskNotChangeRisk() {
        val summary = ToolInputSummary.of(call("Read", filePath = "/etc/hosts"))
        assertEquals(ApprovalRisk.READS_FILES, summary.risk)
        assertEquals("/etc/hosts", summary.primary)
    }

    @Test
    fun aWebFetchShowsTheAddress() {
        val summary = ToolInputSummary.of(call("WebFetch", detail = "https://example.com"))
        assertEquals(ToolInputKind.WEB, summary.kind)
        assertEquals("https://example.com", summary.primary)
        assertEquals(ApprovalRisk.FETCHES_WEB, summary.risk)
    }

    @Test
    fun anUnknownToolShowsItsDetailOrTitle() {
        val summary = ToolInputSummary.of(call("TodoWrite", title = "Update plan", detail = "3 items"))
        assertEquals(ToolInputKind.OTHER, summary.kind)
        assertEquals("3 items", summary.primary)
        assertEquals(ApprovalRisk.USES_TOOL, summary.risk)
    }

    @Test
    fun toolNamesMatchWhateverTheCliCalledThemInAnyCase() {
        assertEquals(ToolInputKind.COMMAND, ToolInputSummary.of(call("  SHELL ", detail = "ls")).kind)
    }
}

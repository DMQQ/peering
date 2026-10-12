package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.AgentPermissionMode

class PermissionModeCopyTest {
    @Test
    fun claudeCanAskSoItsAcceptEditsSaysCommandsStillAsk() {
        assertEquals(PermissionDetail.EDITS_WITHOUT_ASKING, PermissionModeCopy.detail(AgentPermissionMode.ACCEPT_EDITS, "claude"))
    }

    @Test
    fun otherCliCannotAskSoItsModesStayInsideTheFolder() {
        assertEquals(PermissionDetail.WORKS_INSIDE_FOLDER, PermissionModeCopy.detail(AgentPermissionMode.ACCEPT_EDITS, "codex"))
        assertEquals(PermissionDetail.NEVER_ASKS, PermissionModeCopy.detail(AgentPermissionMode.AUTO, "opencode"))
    }

    @Test
    fun claudeAutoHasAReviewerAndManualAlwaysAsks() {
        assertEquals(PermissionDetail.REVIEWER_CHECKS, PermissionModeCopy.detail(AgentPermissionMode.AUTO, "claude"))
        assertEquals(PermissionDetail.ASKS_BEFORE_ACTING, PermissionModeCopy.detail(AgentPermissionMode.MANUAL, null))
    }

    @Test
    fun planOnlyPlansForEveryAgent() {
        assertEquals(PermissionDetail.PLANS_ONLY, PermissionModeCopy.detail(AgentPermissionMode.PLAN, "codex"))
    }
}

package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test

class AgentCatalogTest {
    @Test
    fun knownAgentsGetTheirDisplayNames() {
        assertEquals(
            listOf(AgentOption("claude", "Claude Code"), AgentOption("codex", "Codex")),
            AgentCatalog.options(listOf("claude", "codex")),
        )
    }

    @Test
    fun unknownAgentIsNamedByItsID() {
        assertEquals(listOf(AgentOption("aider", "aider")), AgentCatalog.options(listOf("aider")))
    }

    @Test
    fun declaredOrderIsKeptAndDuplicatesDropped() {
        val ids = AgentCatalog.options(listOf("opencode", "claude", "opencode")).map { it.id }
        assertEquals(listOf("opencode", "claude"), ids)
    }
}

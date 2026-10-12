package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test

class AgentBrandTest {
    @Test
    fun `the three known ids map to their brand`() {
        assertEquals(AgentBrand.CLAUDE, AgentBrand.of("claude"))
        assertEquals(AgentBrand.CODEX, AgentBrand.of("codex"))
        assertEquals(AgentBrand.OPENCODE, AgentBrand.of("opencode"))
    }

    @Test
    fun `an id this build does not know is other`() {
        assertEquals(AgentBrand.OTHER, AgentBrand.of("aider"))
    }
}

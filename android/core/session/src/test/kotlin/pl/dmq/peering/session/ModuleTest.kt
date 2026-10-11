package pl.dmq.peering.session

import org.junit.Assert.assertEquals
import org.junit.Test

class ModuleTest {
    @Test
    fun theModuleBuildsAndSeesTheWireModule() {
        assertEquals("core-session", MODULE_NAME)
        assertEquals(20, pl.dmq.peering.wire.PROTOCOL_VERSION)
    }
}

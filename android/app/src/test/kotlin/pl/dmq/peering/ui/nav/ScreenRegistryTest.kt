package pl.dmq.peering.ui.nav

import org.junit.Assert.assertSame
import org.junit.Test

class ScreenRegistryTest {
    @Test
    fun everyDestinationHasADefaultSlot() {
        assertSame(ScreenRegistry.connect, ScreenRegistry.slotFor(PeeringDestination.Connect))
        assertSame(ScreenRegistry.sessions, ScreenRegistry.slotFor(PeeringDestination.Sessions))
        assertSame(ScreenRegistry.settings, ScreenRegistry.slotFor(PeeringDestination.Settings))
    }
}

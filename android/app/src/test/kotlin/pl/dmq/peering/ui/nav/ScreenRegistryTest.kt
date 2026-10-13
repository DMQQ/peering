package pl.dmq.peering.ui.nav

import org.junit.Assert.assertSame
import org.junit.Test

class ScreenRegistryTest {
    @Test
    fun eachDestinationShowsTheSlotRegisteredForIt() {
        val connect: ScreenSlot = {}
        val sessions: ScreenSlot = {}
        val settings: ScreenSlot = {}
        ScreenRegistry.connect = connect
        ScreenRegistry.sessions = sessions
        ScreenRegistry.settings = settings
        assertSame(connect, ScreenRegistry.slotFor(PeeringDestination.Connect))
        assertSame(sessions, ScreenRegistry.slotFor(PeeringDestination.Sessions))
        assertSame(settings, ScreenRegistry.slotFor(PeeringDestination.Settings))
    }
}

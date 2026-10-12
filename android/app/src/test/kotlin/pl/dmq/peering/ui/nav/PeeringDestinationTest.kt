package pl.dmq.peering.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PeeringDestinationTest {
    @Test
    fun routesAreUnique() {
        val routes = PeeringDestination.entries.map { it.route }
        assertEquals(routes.size, routes.toSet().size)
    }

    @Test
    fun navigationOrderIsConnectSessionsFaqSettings() {
        assertEquals(
            listOf(PeeringDestination.Connect, PeeringDestination.Sessions, PeeringDestination.Faq, PeeringDestination.Settings),
            PeeringDestination.entries,
        )
    }

    @Test
    fun everyRouteIsNonBlank() {
        assertTrue(PeeringDestination.entries.all { it.route.isNotBlank() })
    }
}

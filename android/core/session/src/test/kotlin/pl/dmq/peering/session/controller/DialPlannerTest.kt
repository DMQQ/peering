package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import kotlin.time.Duration

class DialPlannerTest {
    private val seen = PeerAddress("192.168.1.20", 51515)
    private val earlier = PeerAddress("192.168.1.21", 51515)

    @Test
    fun aHostSeenOnTheNetworkIsDialledThereAndTheRelayOnlyAfterItFails() {
        val steps = DialPlanner.plan(DialInputs(discovered = seen, remembered = earlier, relayAllowed = true))

        assertEquals(
            listOf(DialStep.Lan(seen, DialPlanner.SEEN_TIMEOUT), DialStep.Relay(startsAfter = null)),
            steps,
        )
    }

    @Test
    fun aRememberedAddressIsDialledFirstWithTheRelayRacingBehindAHeadStart() {
        val steps = DialPlanner.plan(DialInputs(discovered = null, remembered = earlier, relayAllowed = true))

        assertEquals(
            listOf(DialStep.Lan(earlier, DialPlanner.REMEMBERED_TIMEOUT), DialStep.Relay(DialPlanner.RELAY_HEAD_START)),
            steps,
        )
    }

    @Test
    fun aHostNobodyHasSeenGoesToTheRelay() {
        val steps = DialPlanner.plan(DialInputs(discovered = null, remembered = null, relayAllowed = true))

        assertEquals(listOf<DialStep>(DialStep.Relay(Duration.ZERO)), steps)
    }

    @Test
    fun pairingElsewhereSkipsTheLocalNetworkEvenWhenTheHostIsSeen() {
        val steps = DialPlanner.plan(DialInputs(discovered = seen, remembered = earlier, relayAllowed = true, pairElsewhere = true))

        assertEquals(listOf<DialStep>(DialStep.Relay(Duration.ZERO)), steps)
    }

    @Test
    fun withoutTheRelayOnlyTheLocalNetworkIsTried() {
        val steps = DialPlanner.plan(DialInputs(discovered = seen, remembered = null, relayAllowed = false))

        assertEquals(listOf<DialStep>(DialStep.Lan(seen, DialPlanner.SEEN_TIMEOUT)), steps)
    }

    @Test
    fun nothingIsPlannedWhenNoRouteIsAllowedAndNoAddressIsKnown() {
        assertTrue(DialPlanner.plan(DialInputs(null, null, relayAllowed = false)).isEmpty())
    }

    @Test
    fun theRelayIsNeverFirstWhileALocalAddressIsKnown() {
        for (discovered in listOf(seen, null)) {
            for (remembered in listOf(earlier, null)) {
                if (discovered == null && remembered == null) continue
                val first = DialPlanner.plan(DialInputs(discovered, remembered, relayAllowed = true)).first()
                assertTrue(first is DialStep.Lan)
            }
        }
    }
}

package pl.dmq.peering.platform.net

import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class NetworkMovesTest {
    @Test
    fun theFirstEventOnlyNamesTheStartingNetworkAndALostNetworkIsNotAMove() = runTest {
        val changes = flowOf(
            NetworkChange.Available(TransportKind.WIFI),
            NetworkChange.PathChanged(TransportKind.CELLULAR),
            NetworkChange.Lost,
            NetworkChange.Available(TransportKind.WIFI),
        )

        assertEquals(
            listOf(NetworkChange.PathChanged(TransportKind.CELLULAR), NetworkChange.Available(TransportKind.WIFI)),
            changes.movesOnly().toList(),
        )
    }

    @Test
    fun aSingleEventIsNoMove() = runTest {
        assertEquals(emptyList<NetworkChange>(), flowOf(NetworkChange.Available(TransportKind.WIFI)).movesOnly().toList())
    }
}

package pl.dmq.peering.platform.net

import kotlinx.coroutines.flow.flow
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

    @Test
    fun aCollectionThatBeganOfflineCountsItsFirstEventAsAMove() = runTest {
        val changes = flowOf(NetworkChange.Available(TransportKind.WIFI))

        assertEquals(
            listOf<NetworkChange>(NetworkChange.Available(TransportKind.WIFI)),
            changes.movesOnly(startedOnline = false).toList(),
        )
    }

    @Test
    fun aFailingRegistrationDoesNotCrashTheScope() = runTest {
        val changes = flow<NetworkChange> { throw SecurityException("no ACCESS_NETWORK_STATE") }
        var moves = 0

        changes.followMoves(this, onMoved = { moves++ }).join()

        assertEquals(0, moves)
    }

    @Test
    fun movesAreReported() = runTest {
        val changes = flowOf(NetworkChange.Available(TransportKind.WIFI), NetworkChange.PathChanged(TransportKind.CELLULAR))
        var moves = 0

        changes.followMoves(this, onMoved = { moves++ }).join()

        assertEquals(1, moves)
    }
}

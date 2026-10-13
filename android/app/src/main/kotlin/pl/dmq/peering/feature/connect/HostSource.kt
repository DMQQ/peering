package pl.dmq.peering.feature.connect

import kotlinx.coroutines.flow.Flow
import pl.dmq.peering.session.ports.DiscoveredHost

/** The hosts this device can see now, and the ones it has paired with. */
interface HostSource {
    /** The hosts answering discovery. Emits the whole list each time it changes. */
    fun nearbyHosts(): Flow<List<DiscoveredHost>>

    fun pairedHosts(): Flow<List<PairedHost>>

    /** Removes the pin for [hostId]. False when the removal did not persist. */
    fun forget(hostId: String): Boolean

    /** Names [hostId] on this device only; a blank name restores the one the computer gave itself. */
    fun rename(hostId: String, name: String)

    /** Starts discovery again, after it found nothing or stopped. */
    fun restartSearch()
}

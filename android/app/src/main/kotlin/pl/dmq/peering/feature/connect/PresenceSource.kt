package pl.dmq.peering.feature.connect

import kotlinx.coroutines.flow.Flow

/** What the relay and the live session say about the hosts. */
interface PresenceSource {
    /** The paired hosts the relay reports as up. */
    fun onlineHostIds(): Flow<Set<String>>

    /** The host this device is connected to now, or null. */
    fun connectedHostId(): Flow<String?>
}

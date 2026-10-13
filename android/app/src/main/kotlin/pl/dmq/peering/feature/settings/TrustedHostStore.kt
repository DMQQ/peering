package pl.dmq.peering.feature.settings

import kotlinx.coroutines.flow.Flow

interface TrustedHostStore {
    fun trustedHosts(): Flow<List<TrustedHost>>

    /** Removes the pin for [hostId]. False when the removal did not persist. */
    fun forget(hostId: String): Boolean
}

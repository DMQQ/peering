package pl.dmq.peering.session.ports

import kotlinx.coroutines.flow.Flow

/** Finds hosts on the local network. */
interface Discovery {
    /** Emits each host as it is found. A host may appear more than once as its address changes. */
    fun hosts(): Flow<DiscoveredHost>
}

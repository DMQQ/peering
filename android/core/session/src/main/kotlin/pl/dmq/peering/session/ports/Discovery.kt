package pl.dmq.peering.session.ports

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** Finds hosts on the local network. Every collection starts a fresh search, so what it emits is resolved now, not remembered. */
interface Discovery {
    /** Emits each host as it is found. A host may appear more than once as its address changes. */
    fun hosts(): Flow<DiscoveredHost>

    /** Like [hosts], and also says when a host goes away. */
    fun events(): Flow<DiscoveryEvent> = hosts().map(DiscoveryEvent::Found)
}

package pl.dmq.peering.session.hosts

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.history.SessionRecord

/** The names of the Macs this device has paired with, so a paired Mac is named even while it is offline. */
interface HostDirectory {
    /** Every known Mac, by device ID. Emits the whole map each time it changes. */
    val known: StateFlow<Map<String, KnownHost>>

    /** Remembers the name a Mac gave itself and the route a session to it took. A blank name is ignored. */
    fun remember(hostId: String, name: String, path: SessionRecord.Path)

    fun forget(hostId: String)
}

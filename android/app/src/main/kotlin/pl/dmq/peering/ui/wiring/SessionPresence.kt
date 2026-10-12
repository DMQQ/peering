package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import pl.dmq.peering.feature.connect.PresenceSource

/**
 * Which host the session is on. The relay's presence is not polled yet, so no host is reported online and the list
 * shows each Mac from the phone's own knowledge of it.
 */
internal class SessionPresence(private val holder: SessionHolder) : PresenceSource {
    override fun onlineHostIds(): Flow<Set<String>> = flowOf(emptySet())

    override fun connectedHostId(): Flow<String?> = holder.active.flatMapLatest { active ->
        if (active == null) {
            flowOf(null)
        } else {
            active.controller.state.map { connectedHostId(it.phase, active.target.hostId) }
        }
    }
}

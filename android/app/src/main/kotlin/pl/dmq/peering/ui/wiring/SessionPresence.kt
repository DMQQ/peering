package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.flowOf
import pl.dmq.peering.feature.connect.PresenceSource
import pl.dmq.peering.session.relay.PresenceWatch

/** Which paired hosts the relay reports up, and which host the session is on. The relay is asked only while Connect is shown. */
internal class SessionPresence(
    private val holder: SessionHolder,
    private val relay: PresenceWatch,
) : PresenceSource {
    override fun onlineHostIds(): Flow<Set<String>> = relay.onlineHostIds

    override fun connectedHostId(): Flow<String?> = holder.active.flatMapLatest { active ->
        if (active == null) {
            flowOf(null)
        } else {
            active.controller.state.map { connectedHostId(it.phase, active.target.hostId) }
        }
    }

    fun setShown(visible: Boolean) {
        relay.setShown(visible)
    }
}

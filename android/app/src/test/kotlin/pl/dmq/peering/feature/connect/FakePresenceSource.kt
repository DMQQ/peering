package pl.dmq.peering.feature.connect

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

class FakePresenceSource(
    online: Set<String> = emptySet(),
    connected: String? = null,
) : PresenceSource {
    val online = MutableStateFlow(online)
    val connected = MutableStateFlow(connected)

    override fun onlineHostIds(): Flow<Set<String>> = online

    override fun connectedHostId(): Flow<String?> = connected
}

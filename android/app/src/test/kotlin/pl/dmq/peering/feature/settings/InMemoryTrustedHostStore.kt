package pl.dmq.peering.feature.settings

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

class InMemoryTrustedHostStore(
    hosts: List<TrustedHost> = emptyList(),
    private val forgetSucceeds: Boolean = true,
) : TrustedHostStore {
    private val current = MutableStateFlow(hosts)
    val forgotten = mutableListOf<String>()

    override fun trustedHosts(): Flow<List<TrustedHost>> = current

    override fun forget(hostId: String): Boolean {
        forgotten += hostId
        if (forgetSucceeds) current.value = current.value.filterNot { it.id == hostId }
        return forgetSucceeds
    }
}

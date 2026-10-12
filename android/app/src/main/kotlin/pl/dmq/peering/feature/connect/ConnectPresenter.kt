package pl.dmq.peering.feature.connect

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.pairing.HostIdEntryPresenter
import pl.dmq.peering.feature.pairing.QrSource

class ConnectPresenter(
    private val hosts: HostSource,
    presence: PresenceSource,
    qrSource: QrSource,
    private val onConnect: (String) -> Unit,
    private val onPair: (String) -> Unit,
    scope: CoroutineScope,
) {
    val entry = HostIdEntryPresenter(qrSource, scope, onAccepted = onPair)

    private val pendingForgetId = MutableStateFlow<String?>(null)
    private val message = MutableStateFlow<ConnectMessage?>(null)

    private val listing = combine(
        hosts.nearbyHosts(),
        hosts.pairedHosts(),
        presence.onlineHostIds(),
        presence.connectedHostId(),
    ) { nearby, paired, online, connected -> HostListing.of(nearby, paired, online, connected) }

    val state: StateFlow<ConnectUiState> = combine(
        listing,
        pendingForgetId,
        message,
        entry.state,
    ) { current, pending, failure, entryState ->
        ConnectUiState(
            listing = current,
            forgetTarget = current.paired.firstOrNull { it.id == pending },
            message = failure,
            entry = entryState,
        )
    }.stateIn(scope, SharingStarted.Eagerly, ConnectUiState(entry = entry.state.value))

    fun connect(hostId: String) {
        onConnect(hostId)
    }

    fun pair(hostId: String) {
        onPair(hostId)
    }

    fun requestForget(hostId: String) {
        if (state.value.listing.paired.any { it.id == hostId }) pendingForgetId.value = hostId
    }

    fun cancelForget() {
        pendingForgetId.value = null
    }

    fun confirmForget() {
        val hostId = pendingForgetId.value ?: return
        pendingForgetId.value = null
        message.value = if (hosts.forget(hostId)) null else ConnectMessage.ForgetFailed
    }

    fun searchAgain() {
        hosts.restartSearch()
    }
}

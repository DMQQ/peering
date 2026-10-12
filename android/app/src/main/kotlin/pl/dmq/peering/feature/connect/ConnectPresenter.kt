package pl.dmq.peering.feature.connect

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
    private val onConnectVia: (String, ConnectVia) -> Unit = { hostId, _ -> onConnect(hostId) },
    private val onPair: (String) -> Unit,
    private val onConnectAddress: (ManualAddress) -> Unit,
    private val scope: CoroutineScope,
    network: NetworkSource = NetworkSource.Always,
    private val searchWindowMillis: Long = SEARCH_WINDOW_MILLIS,
) {
    val entry = HostIdEntryPresenter(qrSource, scope, onAccepted = onPair)

    private val pendingForgetId = MutableStateFlow<String?>(null)
    private val message = MutableStateFlow<ConnectMessage?>(null)

    private val searching = MutableStateFlow(true)
    private var searchTimer: Job? = null

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
        combine(network.onLocalNetwork(), searching, ::Pair),
    ) { current, pending, failure, entryState, (onNetwork, stillSearching) ->
        ConnectUiState(
            listing = current,
            nearbyPhase = NearbyPhase.of(onNetwork, current.nearby.size, stillSearching),
            forgetTarget = current.paired.firstOrNull { it.id == pending },
            message = failure,
            entry = entryState,
        )
    }.stateIn(scope, SharingStarted.Eagerly, ConnectUiState(entry = entry.state.value))

    init {
        startSearchWindow()
    }

    fun connect(hostId: String) {
        onConnect(hostId)
    }

    fun connectVia(hostId: String, via: ConnectVia) {
        onConnectVia(hostId, via)
    }

    fun rename(hostId: String, name: String) {
        hosts.rename(hostId, name.trim())
    }

    fun dismissMessage() {
        message.value = null
    }

    fun pair(hostId: String) {
        onPair(hostId)
    }

    /** Dials a computer by the typed address. Fields that are not an address are ignored: the sheet keeps its button off for them. */
    fun connectToAddress(host: String, port: String) {
        ManualAddress.parse(host, port)?.let(onConnectAddress)
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
        searching.value = true
        startSearchWindow()
    }

    /** Discovery never says it is done, so "searching" lasts a fixed window and then gives way to "none found". */
    private fun startSearchWindow() {
        searchTimer?.cancel()
        searchTimer = scope.launch {
            delay(searchWindowMillis)
            searching.value = false
        }
    }

    private companion object {
        const val SEARCH_WINDOW_MILLIS = 6_000L
    }
}

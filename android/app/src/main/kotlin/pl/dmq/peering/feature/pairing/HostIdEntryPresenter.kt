package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import pl.dmq.peering.wire.PairingPayload
import pl.dmq.peering.wire.PairingPayloadError

/** Takes a Mac's device ID typed or scanned, and passes the validated ID to [onAccepted]. */
class HostIdEntryPresenter(
    qrSource: QrSource,
    scope: CoroutineScope,
    private val onAccepted: (String) -> Unit,
) {
    private val text = MutableStateFlow("")
    private val error = MutableStateFlow<HostIdError?>(null)

    val state: StateFlow<HostIdEntryState> = combine(text, error) { typed, failure ->
        HostIdEntryState(text = typed, error = failure)
    }.stateIn(scope, SharingStarted.Eagerly, HostIdEntryState())

    init {
        scope.launch { qrSource.scans().collect { scanned -> onScanned(scanned) } }
    }

    fun onTextChanged(value: String) {
        text.value = value
        error.value = null
    }

    fun submit() {
        accept(text.value)
    }

    fun onScanned(raw: String) {
        text.value = raw
        accept(raw)
    }

    private fun accept(raw: String) {
        try {
            val hostId = PairingPayload.hostId(raw)
            error.value = null
            onAccepted(hostId)
        } catch (refusal: PairingPayloadError) {
            error.value = HostIdError.of(refusal)
        }
    }
}

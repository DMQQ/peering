package pl.dmq.peering.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

class SettingsPresenter(
    private val trusted: TrustedHostStore,
    private val preferences: SettingsStore,
    appVersion: String,
    scope: CoroutineScope,
) {
    private val forgetId = MutableStateFlow<String?>(null)
    private val message = MutableStateFlow<SettingsMessage?>(null)

    val state: StateFlow<SettingsUiState> = combine(
        trusted.trustedHosts(),
        preferences.streamQuality(),
        forgetId,
        message,
    ) { hosts, quality, pendingForget, failure ->
        SettingsUiState(
            trustedHosts = hosts,
            forgetTarget = hosts.firstOrNull { it.id == pendingForget },
            streamQuality = quality,
            message = failure,
            appVersion = appVersion,
        )
    }.stateIn(scope, SharingStarted.Eagerly, SettingsUiState(appVersion = appVersion))

    fun requestForget(hostId: String) {
        if (state.value.trustedHosts.any { it.id == hostId }) forgetId.value = hostId
    }

    fun cancelForget() {
        forgetId.value = null
    }

    fun confirmForget() {
        val hostId = forgetId.value ?: return
        forgetId.value = null
        message.value = if (trusted.forget(hostId)) null else SettingsMessage.ForgetFailed
    }

    fun chooseStreamQuality(quality: StreamQuality) {
        message.value = if (preferences.saveStreamQuality(quality)) null else SettingsMessage.QualitySaveFailed
    }
}

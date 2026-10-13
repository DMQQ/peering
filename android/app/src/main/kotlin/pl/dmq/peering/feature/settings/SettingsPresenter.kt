package pl.dmq.peering.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardMode

class SettingsPresenter(
    private val trusted: TrustedHostStore,
    private val preferences: SettingsStore,
    private val devicePrefs: DevicePreferences,
    deviceId: String,
    paidRelay: StateFlow<Boolean>,
    appVersion: String,
    scope: CoroutineScope,
) {
    private val forgetId = MutableStateFlow<String?>(null)
    private val message = MutableStateFlow<SettingsMessage?>(null)

    val state: StateFlow<SettingsUiState> = combine(
        trusted.trustedHosts(),
        preferences.streamQuality(),
        devicePrefs.prefs,
        paidRelay,
        combine(forgetId, message) { pending, failure -> pending to failure },
    ) { hosts, quality, prefs, paid, (pendingForget, failure) ->
        SettingsUiState(
            trustedHosts = hosts,
            forgetTarget = hosts.firstOrNull { it.id == pendingForget },
            streamQuality = quality,
            message = failure,
            appVersion = appVersion,
            prefs = prefs,
            deviceId = deviceId,
            relayUnlimited = paid,
        )
    }.stateIn(
        scope,
        SharingStarted.Eagerly,
        SettingsUiState(appVersion = appVersion, prefs = devicePrefs.prefs.value, deviceId = deviceId),
    )

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

    /** A blank name is ignored: the computer would show nothing for this phone. */
    fun setDeviceName(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed == state.value.prefs.deviceName) return
        change { it.copy(deviceName = trimmed) }
    }

    fun chooseInteraction(mode: InputMode) = change { it.copy(interaction = mode) }

    fun chooseFill(fills: Boolean) = change { it.copy(fillsScreen = fills) }

    fun chooseKeyboardMode(mode: KeyboardMode) = change { it.copy(keyboardMode = mode) }

    fun setHidesPanelAfterSelect(hides: Boolean) = change { it.copy(hidesPanelAfterSelect = hides) }

    fun setAllowsRelay(allows: Boolean) = change { it.copy(allowsRelay = allows) }

    fun setPlaysComputerSound(plays: Boolean) = change { it.copy(playsComputerSound = plays) }
    fun setKeepsSessionInBackground(keeps: Boolean) = change { it.copy(keepsSessionInBackground = keeps) }

    fun setNotifies(notifies: Boolean) = change { it.copy(notifies = notifies) }

    private fun change(edit: (DevicePrefs) -> DevicePrefs) {
        message.value = if (devicePrefs.update(edit)) null else SettingsMessage.PreferenceSaveFailed
    }
}

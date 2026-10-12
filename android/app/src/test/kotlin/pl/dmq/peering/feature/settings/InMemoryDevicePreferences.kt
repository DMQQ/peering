package pl.dmq.peering.feature.settings

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class InMemoryDevicePreferences(
    initial: DevicePrefs = DevicePrefs(deviceName = "Pixel"),
    private val saveSucceeds: Boolean = true,
) : DevicePreferences {
    private val current = MutableStateFlow(initial)

    override val prefs: StateFlow<DevicePrefs> = current

    override fun update(change: (DevicePrefs) -> DevicePrefs): Boolean {
        if (saveSucceeds) current.value = change(current.value)
        return saveSucceeds
    }
}

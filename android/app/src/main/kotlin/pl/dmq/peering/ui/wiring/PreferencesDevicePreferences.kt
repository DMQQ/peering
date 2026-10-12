package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardMode
import pl.dmq.peering.feature.settings.DevicePreferences
import pl.dmq.peering.feature.settings.DevicePrefs

/** [DevicePreferences] over one SharedPreferences file. An unreadable value falls back to its default. */
internal class PreferencesDevicePreferences(
    private val preferences: SharedPreferences,
    defaultName: String,
) : DevicePreferences {
    private val state = MutableStateFlow(load(defaultName))

    override val prefs: StateFlow<DevicePrefs> = state.asStateFlow()

    override fun update(change: (DevicePrefs) -> DevicePrefs): Boolean {
        val next = change(state.value)
        val saved = preferences.edit()
            .putString(NAME, next.deviceName)
            .putString(INTERACTION, next.interaction.name)
            .putBoolean(FILLS, next.fillsScreen)
            .putString(KEYBOARD, next.keyboardMode.name)
            .putBoolean(HIDES_PANEL, next.hidesPanelAfterSelect)
            .putBoolean(ALLOWS_RELAY, next.allowsRelay)
            .commit()
        if (saved) state.value = next
        return saved
    }

    private fun load(defaultName: String) = DevicePrefs(
        deviceName = preferences.getString(NAME, null)?.takeIf { it.isNotBlank() } ?: defaultName,
        interaction = enumOf(INTERACTION, InputMode.DIRECT).let { if (it == InputMode.TRACKPAD) InputMode.DIRECT else it },
        fillsScreen = preferences.getBoolean(FILLS, false),
        keyboardMode = enumOf(KEYBOARD, KeyboardMode.UNICODE),
        hidesPanelAfterSelect = preferences.getBoolean(HIDES_PANEL, true),
        allowsRelay = preferences.getBoolean(ALLOWS_RELAY, true),
    )

    private inline fun <reified T : Enum<T>> enumOf(key: String, default: T): T =
        enumValues<T>().firstOrNull { it.name == preferences.getString(key, null) } ?: default

    private companion object {
        const val NAME = "device_name"
        const val INTERACTION = "interaction"
        const val FILLS = "fills_screen"
        const val KEYBOARD = "keyboard_mode"
        const val HIDES_PANEL = "hides_panel_after_select"
        const val ALLOWS_RELAY = "allows_relay"
    }
}

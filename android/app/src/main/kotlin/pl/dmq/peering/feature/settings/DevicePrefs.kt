package pl.dmq.peering.feature.settings

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardMode

/** The choices the Settings tab keeps for this phone, read again by every session. */
data class DevicePrefs(
    val deviceName: String,
    val interaction: InputMode = InputMode.DIRECT,
    val fillsScreen: Boolean = false,
    val keyboardMode: KeyboardMode = KeyboardMode.UNICODE,
    val hidesPanelAfterSelect: Boolean = true,
    val allowsRelay: Boolean = true,
    /** Whether what the computer plays comes out of this phone. The computer sends it either way. */
    val playsComputerSound: Boolean = true,
    /** Keeps a session alive in the background behind an ongoing notification. */
    val keepsSessionInBackground: Boolean = true,
    /** Local notifications while connected in the background. */
    val notifies: Boolean = true,
    /** Raises the phone keyboard when the computer focuses a text field. */
    val opensKeyboardForTextFields: Boolean = true,
)

interface DevicePreferences {
    val prefs: StateFlow<DevicePrefs>

    /** Applies [change] and stores it. False when it did not persist, in which case nothing changes. */
    fun update(change: (DevicePrefs) -> DevicePrefs): Boolean
}

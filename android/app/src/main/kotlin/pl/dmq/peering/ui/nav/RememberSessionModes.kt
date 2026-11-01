package pl.dmq.peering.ui.nav

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import pl.dmq.peering.feature.sessionmode.SessionMode
import pl.dmq.peering.feature.sessionmode.SessionModeMemory
import pl.dmq.peering.feature.settings.DevicePreferences
import pl.dmq.peering.session.controller.PictureState
import pl.dmq.peering.session.controller.SessionController
import pl.dmq.peering.ui.wiring.ActiveSession

@Composable
internal fun rememberSessionModes(
    active: ActiveSession,
    memory: SessionModeMemory,
    devicePrefs: DevicePreferences,
    ready: Boolean,
    navigation: SessionNavigation,
): SessionModes {
    var modeKey by rememberSaveable { mutableStateOf<String?>(null) }
    var decided by rememberSaveable { mutableStateOf(false) }
    val prefs by devicePrefs.prefs.collectAsState()
    val modes = remember(active, memory) {
        val controller = active.controller
        SessionModes(
            hostId = active.target.hostId,
            memory = memory,
            picture = ControllerPictureSwitch(controller),
            workspaceOffered = { controller.agentChat != null || controller.files != null || controller.terminals != null },
            navigation = navigation,
            mode = SessionMode.fromKey(modeKey),
        ) { modeKey = it.key }
    }
    LaunchedEffect(ready) {
        if (!ready) return@LaunchedEffect
        modes.ready(prefs.asksHowToUse, firstTime = !decided)
        decided = true
    }
    return modes
}

private class ControllerPictureSwitch(private val controller: SessionController) : PictureSwitch {
    override val pictureOn: Boolean get() = controller.state.value.picture != PictureState.Paused

    override fun setPictureEnabled(enabled: Boolean): Boolean = controller.setPictureEnabled(enabled)
}

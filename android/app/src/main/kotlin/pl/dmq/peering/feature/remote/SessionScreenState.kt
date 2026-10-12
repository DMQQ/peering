package pl.dmq.peering.feature.remote

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.setValue

/**
 * What the session screen has open and what it has chosen, as one value. One floating thing at a time: opening a panel
 * puts the keyboard away and raising the keyboard closes the panel.
 */
@Stable
class SessionScreenState(openPanel: SessionPanel? = null, keyboardShown: Boolean = false) {
    var openPanel by mutableStateOf(openPanel)
        private set
    var keyboardShown by mutableStateOf(keyboardShown)
        private set
    var dockExpanded by mutableStateOf(false)
    var immersive by mutableStateOf(false)
        private set
    var darkened by mutableStateOf(false)
    var speed by mutableStateOf(JoystickMath.SPEEDS.first())
    var speedBadge by mutableStateOf<String?>(null)
    var lastControl by mutableStateOf(InputMode.DIRECT)

    /** The dialogs the screen can ask: leaving, quitting the computer's application, and the macro editor. */
    var leaveAsked by mutableStateOf(false)
    var quitAsked by mutableStateOf(false)
    var macrosOpen by mutableStateOf(false)

    fun togglePanel(panel: SessionPanel) {
        openPanel = panelAfterTap(openPanel, panel)
        if (openPanel != null) keyboardShown = false
    }

    fun showPanel(panel: SessionPanel) {
        openPanel = panel
        keyboardShown = false
    }

    fun closePanel() {
        openPanel = null
    }

    fun toggleKeyboard() {
        keyboardShown = !keyboardShown
        if (keyboardShown) openPanel = null
    }

    fun hideKeyboard() {
        keyboardShown = false
    }

    fun enterImmersive() {
        immersive = true
        openPanel = null
    }

    fun leaveImmersive() {
        immersive = false
    }

    fun backStep(): BackStep = BackStep.of(openPanel != null, keyboardShown)

    companion object {
        val Saver: Saver<SessionScreenState, Any> = listSaver(
            save = { listOf(it.openPanel?.name, it.keyboardShown, it.dockExpanded, it.immersive, it.darkened, it.speed, it.lastControl.name) },
            restore = { saved ->
                SessionScreenState(
                    openPanel = (saved[0] as String?)?.let(SessionPanel::valueOf),
                    keyboardShown = saved[1] as Boolean,
                ).also {
                    it.dockExpanded = saved[2] as Boolean
                    it.immersive = saved[3] as Boolean
                    it.darkened = saved[4] as Boolean
                    it.speed = saved[5] as Double
                    it.lastControl = InputMode.valueOf(saved[6] as String).let { mode -> if (mode == InputMode.TRACKPAD) InputMode.DIRECT else mode }
                }
            },
        )
    }
}

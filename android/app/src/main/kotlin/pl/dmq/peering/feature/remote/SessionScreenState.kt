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
        /** Reads a saved bundle leniently: a field that is missing or no longer fits falls back to its default. */
        internal fun restored(saved: List<Any?>): SessionScreenState {
            val panel = (saved.getOrNull(0) as? String)?.let { name -> SessionPanel.entries.firstOrNull { it.name == name } }
            val control = (saved.getOrNull(6) as? String)?.let { name -> InputMode.entries.firstOrNull { it.name == name } }
            return SessionScreenState(openPanel = panel, keyboardShown = saved.getOrNull(1) as? Boolean ?: false).also {
                it.dockExpanded = saved.getOrNull(2) as? Boolean ?: false
                it.immersive = saved.getOrNull(3) as? Boolean ?: false
                it.darkened = saved.getOrNull(4) as? Boolean ?: false
                it.speed = saved.getOrNull(5) as? Double ?: JoystickMath.SPEEDS.first()
                it.lastControl = if (control == null || control == InputMode.TRACKPAD) InputMode.DIRECT else control
            }
        }

        val Saver: Saver<SessionScreenState, Any> = listSaver(
            save = { listOf(it.openPanel?.name, it.keyboardShown, it.dockExpanded, it.immersive, it.darkened, it.speed, it.lastControl.name) },
            restore = ::restored,
        )
    }
}

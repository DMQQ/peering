package pl.dmq.peering.feature.remote

/** The panels that open over the picture, one at a time. */
enum class SessionPanel { SHORTCUTS, CLIPBOARD, SOURCES, SETTINGS }

/** Everything the session chrome draws from. */
class ChromeState(
    val shown: Boolean,
    val immersive: Boolean,
    val overlay: SessionOverlayState,
    val status: StatusUi,
    val statusExpanded: Boolean,
    val openPanel: SessionPanel?,
    val keyboardShown: Boolean,
    val dockExpanded: Boolean,
    val interaction: InputMode,
    val profile: ApplicationProfile?,
    /** The zoom as a fraction of its range while observing, which turns the wheel into a gauge; null while controlling. */
    val wheelPosition: Float?,
    val speedText: String?,
)

/** Everything the session chrome can ask for. */
class ChromeHandlers(
    val status: StatusActions,
    val onStatusExpanded: (Boolean) -> Unit,
    val onReveal: () -> Unit,
    val onRetry: () -> Unit,
    val onPanel: (SessionPanel) -> Unit,
    val onKeyboard: () -> Unit,
    val onDockExpanded: (Boolean) -> Unit,
    val onKey: (keyCode: Int, modifiers: Long) -> Unit,
    val onDelete: () -> Unit,
    val onChord: (QuickAction) -> Unit,
    val onMode: () -> Unit,
    val onNotch: (Int) -> Unit,
    val pointer: PointerActions,
    val keyboardKeys: KeyboardKeys,
)

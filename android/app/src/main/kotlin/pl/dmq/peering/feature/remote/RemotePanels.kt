package pl.dmq.peering.feature.remote

import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.wire.Modifiers

/** What the panels need that the screen already holds. */
internal class PanelContext(
    val model: RemoteModel,
    val state: RemoteUiState,
    val prefs: DevicePrefs,
    val screen: SessionScreenState,
    val actions: RemoteActions,
    val keyboard: KeyboardPresenter,
    val sources: SourcesPresenter,
    val quality: QualitySheetPresenter,
    val customMacros: List<Macro>,
    val overlay: SessionOverlayState,
)

/** The content of whichever panel is open. */
@Composable
internal fun RemotePanel(panel: SessionPanel, context: PanelContext) {
    val latches by context.keyboard.latches.collectAsState()
    val ui by context.quality.ui.collectAsState()
    val macros = remember(context.customMacros) { Macros.defaults + context.customMacros }
    when (panel) {
        SessionPanel.SHORTCUTS -> ShortcutsPanelContent(context, macros, latches)
        SessionPanel.CLIPBOARD -> ClipboardPanelContent(context)
        SessionPanel.SOURCES -> SourcesPanelContent(context)
        SessionPanel.SETTINGS -> SettingsPanelContent(context, ui, macros)
    }
}

@Composable
private fun ShortcutsPanelContent(context: PanelContext, macros: List<Macro>, latches: Map<StickyModifier, ModifierLatch>) {
    ShortcutsPanel(
        profile = ApplicationProfiles.forBundle(context.state.sourceBundleId),
        macros = macros,
        latches = latches,
        actions = ShortcutsActions(
            onKey = context.actions::sendKey,
            onTopRowAction = { code -> context.actions.sendKey(code, Modifiers.TOP_ROW_ACTION) },
            onModifier = { context.keyboard.onModifierTap(it, SystemClock.uptimeMillis()) },
            onDelete = context.keyboard::onSoftKeyboardDelete,
            onEnter = context.keyboard::pressEnter,
            onEditMacros = { context.screen.macrosOpen = true },
        ),
    )
}

@Composable
private fun ClipboardPanelContent(context: PanelContext) {
    val history by context.model.clipboard.history.collectAsState()
    ClipboardPanel(
        ClipboardActions(
            ready = context.state.hostName != null,
            host = context.state.hostClipboard,
            imagesAllowed = context.state.clipboardImages,
            history = history,
            onRequestHost = context.actions::requestHostClipboard,
            onSend = context.actions::send,
            onPasteOnComputer = context.actions::paste,
            onSendImage = context.actions::sendImage,
            onRemoveEntry = context.model.clipboard::remove,
            onClearHistory = context.model.clipboard::clear,
        ),
    )
}

@Composable
private fun SourcesPanelContent(context: PanelContext) {
    SourcesPanel(
        catalog = context.state.catalog,
        chosen = context.state.chosenSource,
        presenter = context.sources,
        onPicked = { if (context.prefs.hidesPanelAfterSelect) context.screen.closePanel() },
        mosaic = MosaicPanel(context.state.mosaic, context.state.rememberedMosaic).takeIf { context.state.supportsMosaic },
    )
}

@Composable
private fun SettingsPanelContent(context: PanelContext, ui: QualitySheetUi, macros: List<Macro>) {
    SessionSettingsPanel(
        model = SessionSettingsModel(
            context.overlay, context.prefs, ui, context.screen.darkened, macros,
            SessionFacts.of(context.state.directPath, context.state.videoStream),
        ),
        actions = SessionSettingsActions(
            onShowSources = { context.screen.showPanel(SessionPanel.SOURCES) },
            onChooseQuality = context.quality::choose,
            onSetHidesPanel = { value -> context.model.prefs.update { it.copy(hidesPanelAfterSelect = value) } },
            onSetAllowsRelay = { value -> context.model.prefs.update { it.copy(allowsRelay = value) } },
            onToggleDark = context.actions::toggleDark,
            onKeyboardMode = { mode -> context.model.prefs.update { it.copy(keyboardMode = mode) } },
            onLock = context.actions::lock,
            onRename = { name -> if (name.isNotBlank()) context.model.prefs.update { it.copy(deviceName = name.trim()) } },
            onRunMacro = context.actions::runMacro,
        ),
    )
}

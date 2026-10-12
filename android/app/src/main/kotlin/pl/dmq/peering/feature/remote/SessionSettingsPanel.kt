package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.feature.settings.SettingsSearch
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.ui.kit.SearchField
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** What the session's Settings panel shows. */
class SessionSettingsModel(
    val overlay: SessionOverlayState,
    val prefs: DevicePrefs,
    val quality: QualitySheetUi,
    val darkened: Boolean,
    val macros: List<Macro>,
)

/** What the session's Settings panel does. */
class SessionSettingsActions(
    val onShowSources: () -> Unit,
    val onChooseQuality: (StreamQuality) -> Unit,
    val onSetHidesPanel: (Boolean) -> Unit,
    val onSetAllowsRelay: (Boolean) -> Unit,
    val onToggleDark: () -> Unit,
    val onKeyboardMode: (KeyboardMode) -> Unit,
    val onLock: () -> Unit,
    val onRename: (String) -> Unit,
    val onRunMacro: (Macro) -> Unit,
)

internal enum class PanelSection(val keywordsRes: Int) {
    Session(R.string.panel_keywords_session),
    Stream(R.string.panel_keywords_stream),
    Panels(R.string.panel_keywords_panels),
    Privacy(R.string.panel_keywords_privacy),
    Keyboard(R.string.panel_keywords_keyboard),
    Macros(R.string.panel_keywords_macros),
    Device(R.string.panel_keywords_device),
}

/**
 * The Settings panel inside a session: the session's facts, the stream, the panels, privacy, the keyboard, the macros and
 * this device, in the order the phone lists them, narrowed by its search field.
 */
@Composable
fun SessionSettingsPanel(model: SessionSettingsModel, actions: SessionSettingsActions, modifier: Modifier = Modifier) {
    var query by rememberSaveable { mutableStateOf("") }
    val shown = PanelSection.entries.filter { SettingsSearch.matches(stringResource(it.keywordsRes), query) }
    Column(
        modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SearchField(query, { query = it }, stringResource(R.string.settings_search), height = 34.dp)
        shown.forEach { section ->
            when (section) {
                PanelSection.Session -> SessionInfoSection(model, actions)
                PanelSection.Stream -> StreamSection(model, actions)
                PanelSection.Panels -> PanelsSection(model, actions)
                PanelSection.Privacy -> PrivacySection(model, actions)
                PanelSection.Keyboard -> KeyboardSection(model, actions)
                PanelSection.Macros -> MacrosSection(model, actions)
                PanelSection.Device -> DeviceSection(model, actions)
            }
        }
        if (shown.isEmpty()) {
            Text(
                stringResource(R.string.settings_no_match, query),
                style = PeeringText.subheadline,
                color = PeeringColors.muted,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
            )
        }
    }
}

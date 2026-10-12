package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardMode
import pl.dmq.peering.ui.kit.ControlPicker
import pl.dmq.peering.ui.kit.ControlRow
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

@Composable
internal fun DeviceCard(name: String, onRename: (String) -> Unit) {
    ControlsCard(stringResource(R.string.settings_device_heading), footer = stringResource(R.string.settings_device_footer)) {
        ControlRow(stringResource(R.string.settings_device_name), SessionIcons.phone) { DeviceNameField(name, onRename) }
    }
}

@Composable
private fun DeviceNameField(name: String, onRename: (String) -> Unit) {
    var draft by remember(name) { mutableStateOf(name) }
    BasicTextField(
        value = draft,
        onValueChange = { draft = it },
        singleLine = true,
        textStyle = PeeringText.subheadline.copy(color = PeeringColors.muted, textAlign = TextAlign.End),
        cursorBrush = SolidColor(PeeringColors.accent),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onRename(draft) }),
        modifier = Modifier.widthIn(min = 96.dp, max = 200.dp).onFocusChanged { if (!it.isFocused) onRename(draft) },
    )
}

@Composable
internal fun SessionControlsCard(prefs: DevicePrefs, presenter: SettingsPresenter) {
    ControlsCard(stringResource(R.string.settings_controls_heading), footer = stringResource(prefs.keyboardMode.explanationRes())) {
        ControlPicker(
            title = stringResource(R.string.settings_interaction),
            icon = SessionIcons.hand,
            selected = prefs.interaction,
            options = listOf(InputMode.DIRECT, InputMode.OBSERVE),
            optionTitle = { stringResource(it.labelRes()) },
            onSelect = presenter::chooseInteraction,
        )
        ControlsDivider()
        ControlPicker(
            title = stringResource(R.string.settings_picture),
            icon = AppIcons.fit,
            selected = prefs.fillsScreen,
            options = listOf(false, true),
            optionTitle = { stringResource(if (it) R.string.settings_picture_fill else R.string.settings_picture_fit) },
            onSelect = presenter::chooseFill,
        )
        ControlsDivider()
        ControlPicker(
            title = stringResource(R.string.settings_keyboard),
            icon = SessionIcons.keyboard,
            selected = prefs.keyboardMode,
            options = KeyboardMode.entries,
            optionTitle = { stringResource(it.labelRes()) },
            onSelect = presenter::chooseKeyboardMode,
        )
        ControlsDivider()
        ControlToggle(
            stringResource(R.string.settings_close_panels),
            SessionIcons.apps,
            prefs.hidesPanelAfterSelect,
            presenter::setHidesPanelAfterSelect,
        )
    }
}

@Composable
internal fun StreamQualityCard(current: StreamQuality, onChoose: (StreamQuality) -> Unit) {
    ControlsCard(stringResource(R.string.settings_quality_heading), footer = stringResource(R.string.settings_quality_footer)) {
        ControlPicker(
            title = stringResource(R.string.settings_quality_row),
            icon = SessionIcons.speed,
            selected = current,
            options = StreamQuality.entries,
            optionTitle = { stringResource(it.menuRes()) },
            onSelect = onChoose,
        )
    }
}

@Composable
internal fun RemoteAccessCard(state: SettingsUiState, onAllowRelay: (Boolean) -> Unit, onSeePlans: () -> Unit) {
    ControlsCard(stringResource(R.string.settings_remote_heading), footer = stringResource(R.string.settings_remote_footer)) {
        ControlToggle(stringResource(R.string.settings_allow_relay), AppIcons.network, state.prefs.allowsRelay, onAllowRelay)
        if (!state.relayUnlimited) {
            ControlsDivider()
            ControlLink(stringResource(R.string.settings_upgrade), AppIcons.sparkles, onSeePlans)
        }
    }
}

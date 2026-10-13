package pl.dmq.peering.feature.remote

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.platform.video.codecSupport
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringSwitch
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.QualityTier

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            title.uppercase(),
            style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.1.sp),
            color = PeeringColors.muted,
        )
        content()
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = PeeringText.caption2, color = PeeringColors.tertiary)
}

@Composable
private fun InfoRow(title: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = PeeringText.caption, color = PeeringColors.muted)
        Text(
            value,
            style = PeeringText.captionSemibold.copy(fontWeight = FontWeight.Medium),
            color = PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, modifier = Modifier.weight(1f))
        PeeringSwitch(checked, onChange)
    }
}

@Composable
private fun RowButton(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, trailing: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().rowSurface().tappable(onClick).padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
        Text(title, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, modifier = Modifier.weight(1f))
        if (trailing) Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp))
    }
}

@Composable
internal fun SessionInfoSection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    var confirm by rememberSaveable { mutableStateOf(false) }
    val overlay = model.overlay
    Section(stringResource(R.string.panel_session)) {
        InfoRow(stringResource(R.string.remote_computer_fallback), overlay.hostName ?: stringResource(R.string.panel_none))
        InfoRow(stringResource(R.string.panel_state), stateText(overlay))
        InfoRow(stringResource(R.string.sessions_detail_path), overlay.path?.let { stringResource(it.labelRes()) } ?: stringResource(R.string.panel_none))
        model.facts.directPath?.let { InfoRow(stringResource(R.string.panel_direct_path), directPathText(it)) }
        model.facts.video?.let { InfoRow(stringResource(R.string.panel_video), it) }
        overlay.latencyMs?.let { InfoRow(stringResource(R.string.panel_latency), stringResource(R.string.overlay_latency, it)) }
        RowButton(AppIcons.encrypted, stringResource(R.string.panel_lock), trailing = false) { confirm = true }
    }
    if (confirm) {
        PeeringAlert(
            title = stringResource(R.string.panel_lock_title),
            message = stringResource(R.string.panel_lock_message),
            confirm = stringResource(R.string.panel_lock_confirm),
            onConfirm = {
                confirm = false
                actions.onLock()
            },
            cancel = stringResource(R.string.settings_cancel),
            onCancel = { confirm = false },
            destructive = true,
        )
    }
}

@Composable
private fun directPathText(row: DirectPathRow): String = when (row.report) {
    DirectPathReport.NOT_TRIED -> stringResource(R.string.panel_direct_not_tried)
    DirectPathReport.NO_ADDRESS -> stringResource(R.string.panel_direct_no_address)
    DirectPathReport.PROBING -> stringResource(R.string.panel_direct_probing, row.peer.orEmpty())
    DirectPathReport.UNUSABLE -> stringResource(R.string.panel_direct_unusable, row.peer.orEmpty())
}

@Composable
private fun stateText(overlay: SessionOverlayState): String = stringResource(
    when {
        overlay.reconnecting -> R.string.panel_state_reconnecting
        overlay.picture == PictureState.LIVE -> R.string.panel_state_connected
        overlay.picture == PictureState.WAITING -> R.string.panel_state_connecting
        else -> R.string.panel_state_not_streaming
    },
)

@Composable
internal fun StreamSection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    val quality = model.quality
    var lastManual by rememberSaveable { mutableStateOf(StreamQuality.Medium) }
    if (quality.selected != StreamQuality.Auto) lastManual = quality.selected
    val hevc = remember { "hevc" in codecSupport() }
    Section(stringResource(R.string.panel_stream)) {
        RowButton(SessionIcons.apps, stringResource(R.string.panel_display_app_window), trailing = true, onClick = actions.onShowSources)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            listOf(true to R.string.panel_quality_automatic, false to R.string.panel_quality_manual).forEachIndexed { index, (automatic, label) ->
                SegmentedButton(
                    selected = (quality.selected == StreamQuality.Auto) == automatic,
                    onClick = { actions.onChooseQuality(if (automatic) StreamQuality.Auto else lastManual) },
                    shape = SegmentedButtonDefaults.itemShape(index, 2),
                    label = { Text(stringResource(label)) },
                )
            }
        }
        if (quality.selected != StreamQuality.Auto) {
            val levels = listOf(StreamQuality.Low, StreamQuality.Medium, StreamQuality.High)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                levels.forEachIndexed { index, level ->
                    SegmentedButton(
                        selected = quality.selected == level,
                        onClick = { actions.onChooseQuality(level) },
                        shape = SegmentedButtonDefaults.itemShape(index, levels.size),
                        label = { Text(stringResource(level.shortRes())) },
                    )
                }
            }
        }
        Note(stringResource(if (quality.selected == StreamQuality.Auto) R.string.panel_quality_auto_note else R.string.panel_quality_manual_note))
        if (quality.ceiling < QualityTier.HIGH) Note(stringResource(R.string.quality_relay_cap))
        if (quality.saveFailed) Text(stringResource(R.string.quality_save_failed), style = PeeringText.caption2, color = PeeringColors.danger)
        SwitchRow(stringResource(R.string.settings_computer_sound), model.prefs.playsComputerSound, actions.onSetPlaysSound)
        Note(stringResource(if (model.prefs.playsComputerSound) R.string.panel_sound_on_note else R.string.panel_sound_off_note))
        CodecRow(hevc)
    }
}

@Composable
private fun CodecRow(hevc: Boolean) {
    Row(
        Modifier.fillMaxWidth().rowSurface().padding(horizontal = 10.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            if (hevc) AppIcons.verifiedShield else AppIcons.warning,
            contentDescription = null,
            tint = if (hevc) PeeringColors.added else PeeringColors.caution,
            modifier = Modifier.size(18.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(stringResource(if (hevc) R.string.panel_hevc_yes else R.string.panel_hevc_no), style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
            Text(stringResource(if (hevc) R.string.panel_hevc_yes_note else R.string.panel_hevc_no_note), style = PeeringText.caption2, color = PeeringColors.muted)
        }
    }
}

private fun StreamQuality.shortRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.settings_quality_auto
    StreamQuality.Low -> R.string.settings_quality_low
    StreamQuality.Medium -> R.string.settings_quality_medium
    StreamQuality.High -> R.string.settings_quality_high
}

@Composable
internal fun PanelsSection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    Section(stringResource(R.string.panel_panels)) {
        SwitchRow(stringResource(R.string.settings_close_panels), model.prefs.hidesPanelAfterSelect, actions.onSetHidesPanel)
        Note(stringResource(R.string.panel_panels_note))
    }
}

@Composable
internal fun PrivacySection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    Section(stringResource(R.string.panel_privacy)) {
        SwitchRow(stringResource(R.string.panel_allow_relay), model.prefs.allowsRelay, actions.onSetAllowsRelay)
        Note(stringResource(R.string.panel_allow_relay_note))
        SwitchRow(stringResource(R.string.panel_darken), model.darkened) { actions.onToggleDark() }
        Note(stringResource(R.string.panel_darken_note))
    }
}

@Composable
internal fun KeyboardSection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    Section(stringResource(R.string.settings_keyboard)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            KeyboardMode.entries.forEachIndexed { index, mode ->
                SegmentedButton(
                    selected = model.prefs.keyboardMode == mode,
                    onClick = { actions.onKeyboardMode(mode) },
                    shape = SegmentedButtonDefaults.itemShape(index, KeyboardMode.entries.size),
                    label = { Text(stringResource(if (mode == KeyboardMode.UNICODE) R.string.settings_keyboard_unicode else R.string.settings_keyboard_keycode)) },
                )
            }
        }
        Text(
            stringResource(
                if (model.prefs.keyboardMode == KeyboardMode.UNICODE) R.string.settings_keyboard_unicode_explanation else R.string.settings_keyboard_keycode_explanation,
            ),
            style = PeeringText.caption2,
            color = PeeringColors.muted,
        )
        SwitchRow(stringResource(R.string.panel_open_for_text_fields), model.prefs.opensKeyboardForTextFields, actions.onSetOpensKeyboard)
        Note(stringResource(R.string.panel_open_for_text_fields_note))
    }
}

@Composable
internal fun MacrosSection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    Section(stringResource(R.string.panel_macros)) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            model.macros.forEach { macro ->
                Text(
                    macro.title,
                    style = PeeringText.captionSemibold.copy(fontWeight = FontWeight.Medium),
                    color = PeeringColors.ink,
                    maxLines = 1,
                    modifier = Modifier.rowSurface().tappable({ actions.onRunMacro(macro) }).padding(horizontal = 10.dp, vertical = 7.dp),
                )
            }
        }
    }
}

@Composable
internal fun DeviceSection(model: SessionSettingsModel, actions: SessionSettingsActions) {
    var draft by remember(model.prefs.deviceName) { mutableStateOf(model.prefs.deviceName) }
    Section(stringResource(R.string.settings_device_heading)) {
        Row(
            Modifier.fillMaxWidth().rowSurface().padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(SessionIcons.phone, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.settings_device_name), style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
            PeeringTextField(draft, { draft = it; actions.onRename(it) }, stringResource(R.string.settings_device_name), Modifier.weight(1f))
        }
        Note(stringResource(R.string.settings_device_footer))
    }
}

package pl.dmq.peering.feature.settings

import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.clip
import kotlinx.coroutines.delay
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.peeringShapes
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.connect.AppProtection
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlRow
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.PeeringSwitch
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

@Composable
internal fun SecurityCard(protection: AppProtection) {
    ControlsCard(stringResource(R.string.settings_security_heading), footer = stringResource(R.string.settings_security_footer)) {
        ControlRow(stringResource(R.string.settings_require_unlock), AppIcons.fingerprint) {
            PeeringSwitch(protection.enabled, protection.onChange, enabled = protection.available)
        }
    }
}

@Composable
internal fun TrustedHostsCard(hosts: List<TrustedHost>, onForget: (String) -> Unit) {
    ControlsCard(stringResource(R.string.settings_trusted_heading)) {
        hosts.forEachIndexed { index, host ->
            ControlRow(host.name ?: stringResource(R.string.settings_unnamed_host), AppIcons.computer) {
                TextButton(onClick = { onForget(host.id) }) {
                    Text(stringResource(R.string.settings_forget), style = PeeringText.subheadline, color = PeeringColors.danger)
                }
            }
            if (index < hosts.lastIndex) ControlsDivider()
        }
    }
}

@Composable
internal fun IdentityCard(deviceId: String, pairedCount: Int) {
    ControlsCard(stringResource(R.string.settings_identity_heading), footer = stringResource(R.string.settings_identity_footer)) {
        ControlRow(stringResource(R.string.settings_identity_id), AppIcons.number) {
            Text(
                deviceId,
                style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace),
                color = PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 160.dp),
            )
        }
        ControlsDivider()
        ControlRow(stringResource(R.string.settings_identity_key), SessionIcons.key) {
            Text(stringResource(R.string.settings_identity_key_value), style = PeeringText.caption, color = PeeringColors.muted)
        }
        ControlsDivider()
        ControlRow(stringResource(R.string.settings_identity_paired), AppIcons.computer) {
            Text("$pairedCount", style = PeeringText.subheadlineMedium, color = PeeringColors.muted)
        }
    }
}

@Composable
internal fun MoreCard(actions: SettingsActions, state: SettingsUiState) {
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(COPIED_SHOWN_MILLIS)
            copied = false
        }
    }
    ControlsCard(stringResource(R.string.settings_more_heading)) {
        ControlLink(stringResource(R.string.settings_more_host_app), AppIcons.download, actions.onGetHostApp, external = true)
        ControlsDivider()
        ControlLink(stringResource(R.string.settings_more_introduction), SessionIcons.introduction, actions.onShowIntroduction)
        ControlsDivider()
        ControlLink(stringResource(R.string.settings_more_report), SessionIcons.mail, actions.onReportIssue, external = true)
        ControlsDivider()
        ControlRow(
            stringResource(R.string.settings_more_copy_diagnostics),
            if (copied) AppIcons.check else AppIcons.copy,
            Modifier.clip(peeringShapes.extraSmall).tappable({
                actions.onCopyDiagnostics(state)
                copied = true
            }),
        ) {
            if (copied) Text(stringResource(R.string.settings_more_copied), style = PeeringText.captionSemibold, color = PeeringColors.accent)
        }
    }
}

@Composable
internal fun LegalCard(onOpen: (LegalDocument) -> Unit, onOpenWebPage: (String) -> Unit) {
    ControlsCard(stringResource(R.string.settings_legal_heading)) {
        LegalDocument.entries.forEachIndexed { index, document ->
            val web = document.webUrl()
            val open = if (web != null) ({ onOpenWebPage(web) }) else ({ onOpen(document) })
            ControlLink(stringResource(document.labelRes()), document.icon(), open, external = web != null)
            if (index < LegalDocument.entries.lastIndex) ControlsDivider()
        }
    }
}

private const val COPIED_SHOWN_MILLIS = 2_000L

private fun LegalDocument.icon() = if (this == LegalDocument.Privacy) AppIcons.privacy else AppIcons.document

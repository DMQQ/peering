package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.TonalButton
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
internal fun TrustedHostsCard(hosts: List<TrustedHost>, onForget: (String) -> Unit) {
    SettingsCard(heading = stringResource(R.string.settings_trusted_heading)) {
        if (hosts.isEmpty()) {
            Text(
                text = stringResource(R.string.settings_trusted_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.faint,
            )
        }
        hosts.forEach { host ->
            PeeringListItem(
                headline = host.name ?: stringResource(R.string.settings_unnamed_host),
                trailing = {
                    TextButton(onClick = { onForget(host.id) }) {
                        Text(stringResource(R.string.settings_forget), color = PeeringColors.danger)
                    }
                },
            )
        }
    }
}

@Composable
internal fun AboutCard(version: String) {
    SettingsCard(heading = stringResource(R.string.settings_about_heading)) {
        Text(
            text = stringResource(R.string.settings_version, version),
            style = MaterialTheme.typography.bodyLarge,
            color = PeeringColors.ink,
        )
    }
}

@Composable
internal fun RelayTimeCard(onSeePlans: () -> Unit) {
    SettingsCard(heading = stringResource(R.string.settings_relay_heading)) {
        Text(
            text = stringResource(R.string.settings_relay_free),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
        TonalButton(onClick = onSeePlans, modifier = Modifier.padding(top = 12.dp)) {
            Text(stringResource(R.string.settings_relay_see_plans))
        }
    }
}

@Composable
internal fun LegalCard(onOpen: (LegalDocument) -> Unit) {
    SettingsCard(heading = stringResource(R.string.settings_legal_heading)) {
        Column(modifier = Modifier.fillMaxWidth()) {
            LegalDocument.entries.forEach { document ->
                PeeringListItem(
                    headline = stringResource(document.labelRes()),
                    onClick = { onOpen(document) },
                    role = Role.Button,
                    trailing = { Icon(AppIcons.chevronRight, contentDescription = null) },
                )
            }
        }
    }
}

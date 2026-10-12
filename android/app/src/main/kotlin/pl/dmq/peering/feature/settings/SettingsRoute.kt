package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.TitleBarScreen
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringBackdrop

/** The Settings screen. [onOpenLegal] is supplied by the wiring, which decides where the legal pages live. */
@Composable
fun SettingsRoute(
    presenter: SettingsPresenter,
    onOpenLegal: (LegalDocument) -> Unit,
    onSeePlans: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by presenter.state.collectAsState()
    TitleBarScreen(
        title = stringResource(R.string.settings_title),
        detail = stringResource(R.string.settings_detail),
        modifier = modifier.peeringBackdrop(),
    ) {
        state.message?.let {
            Text(
                text = stringResource(it.messageRes()),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
        }
        StreamQualityCard(current = state.streamQuality, onChoose = presenter::chooseStreamQuality)
        TrustedHostsCard(hosts = state.trustedHosts, onForget = presenter::requestForget)
        AboutCard(version = state.appVersion)
        RelayTimeCard(onSeePlans = onSeePlans)
        LegalCard(onOpen = onOpenLegal)
        Spacer(Modifier.height(16.dp))
    }
    if (state.forgetTarget != null) {
        ForgetConfirmDialog(onConfirm = presenter::confirmForget, onDismiss = presenter::cancelForget)
    }
}

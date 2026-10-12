package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
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
    Column(
        modifier = modifier
            .fillMaxSize()
            .peeringBackdrop()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(R.string.settings_title),
            style = MaterialTheme.typography.headlineLarge,
            color = PeeringColors.ink,
        )
        Text(
            text = stringResource(R.string.settings_detail),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
        state.message?.let {
            Text(
                text = stringResource(it.messageRes()),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
        }
        Spacer(Modifier.height(4.dp))
        StreamQualityCard(current = state.streamQuality, onChoose = presenter::chooseStreamQuality)
        TrustedHostsCard(hosts = state.trustedHosts, onForget = presenter::requestForget)
        AboutCard(version = state.appVersion)
        RelayTimeCard(onSeePlans = onSeePlans)
        LegalCard(onOpen = onOpenLegal)
    }
    if (state.forgetTarget != null) {
        ForgetConfirmDialog(onConfirm = presenter::confirmForget, onDismiss = presenter::cancelForget)
    }
}

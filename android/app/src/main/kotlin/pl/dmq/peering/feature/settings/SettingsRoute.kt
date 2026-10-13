package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.connect.AppProtection
import pl.dmq.peering.ui.kit.SearchField
import pl.dmq.peering.ui.kit.TabScreen
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop

/** What the Settings tab can ask the rest of the app to do. */
class SettingsActions(
    val onOpenLegal: (LegalDocument) -> Unit,
    val onSeePlans: () -> Unit,
    val onGetHostApp: () -> Unit,
    val onShowIntroduction: () -> Unit,
    val onReportIssue: () -> Unit,
    val onOpenWebPage: (String) -> Unit,
    val onCopyDiagnostics: (SettingsUiState) -> Unit,
    val onShareInvite: (String) -> Unit,
    /** The user turned notifications on: ask for the permission if it is missing. */
    val onNotificationsTurnedOn: () -> Unit,
    val protection: AppProtection,
)

/** The Settings tab: its cards in the phone's order, narrowed by the search field. */
@Composable
fun SettingsRoute(
    presenter: SettingsPresenter,
    invites: InvitePresenter,
    nowSeconds: () -> Long,
    actions: SettingsActions,
    modifier: Modifier = Modifier,
) {
    val state by presenter.state.collectAsState()
    val inviteState by invites.state.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    val shown = SettingsSection.entries.filter { SettingsSearch.matches(stringResource(it.keywordsRes), query) }
        .filter { it != SettingsSection.Trusted || state.trustedHosts.isNotEmpty() }
    TabScreen(
        title = stringResource(R.string.settings_title),
        detail = stringResource(R.string.settings_detail),
        modifier = modifier.peeringBackdrop(),
    ) {
        SearchField(query, { query = it }, stringResource(R.string.settings_search))
        state.message?.let {
            Text(stringResource(it.messageRes()), style = PeeringText.footnote, color = PeeringColors.danger)
        }
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            shown.forEach { SectionCard(it, state, presenter, actions, InviteSlot(invites, inviteState, nowSeconds)) }
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
    if (state.forgetTarget != null) {
        ForgetConfirmDialog(onConfirm = presenter::confirmForget, onDismiss = presenter::cancelForget)
    }
}

@Composable
private fun SectionCard(
    section: SettingsSection,
    state: SettingsUiState,
    presenter: SettingsPresenter,
    actions: SettingsActions,
    invite: InviteSlot,
) {
    when (section) {
        SettingsSection.Device -> DeviceCard(state.prefs.deviceName, presenter::setDeviceName)
        SettingsSection.Controls -> SessionControlsCard(state.prefs, presenter)
        SettingsSection.Quality -> StreamQualityCard(state.streamQuality, presenter::chooseStreamQuality)
        SettingsSection.RemoteAccess -> RemoteAccessCard(state, presenter::setAllowsRelay, actions.onSeePlans)
        SettingsSection.Background -> BackgroundCard(state.prefs, presenter, actions.onNotificationsTurnedOn)
        SettingsSection.Invite -> InviteCard(invite.state, invite.nowSeconds(), invite.presenter::refresh, invite.presenter::redeem, actions.onShareInvite)
        SettingsSection.Security -> SecurityCard(actions.protection)
        SettingsSection.Trusted -> TrustedHostsCard(state.trustedHosts, presenter::requestForget)
        SettingsSection.Identity -> IdentityCard(state.deviceId, state.trustedHosts.size)
        SettingsSection.More -> MoreCard(actions, state)
        SettingsSection.Legal -> LegalCard(actions.onOpenLegal, actions.onOpenWebPage)
    }
}

private class InviteSlot(val presenter: InvitePresenter, val state: InviteUiState, val nowSeconds: () -> Long)

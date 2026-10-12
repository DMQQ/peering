package pl.dmq.peering.feature.pairing

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.IconButton
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.controller.MAX_PAIRING_ATTEMPTS
import pl.dmq.peering.ui.kit.GuideStepRow
import pl.dmq.peering.ui.kit.GuideStepState
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.StepDetail
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.FailureNotice
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.arrive
import pl.dmq.peering.ui.theme.peeringBackdrop

/** The pairing: four steps down one column, the code entry living inside the second. */
@Composable
fun PairingCodeContent(screen: PairingCodeScreen, actions: PairingActions, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxSize().peeringBackdrop().windowInsetsPadding(WindowInsets.statusBars).imePadding()) {
        val leaves = screen is PairingCodeScreen.Failed || screen is PairingCodeScreen.Done
        IconButton(onClick = if (leaves) actions.onFinished else actions.onCancel, modifier = Modifier.padding(start = 4.dp, top = 4.dp)) {
            Icon(AppIcons.back, contentDescription = stringResource(R.string.pairing_code_cancel))
        }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 22.dp).padding(top = 12.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            Text(
                stringResource(if (screen is PairingCodeScreen.Done) R.string.pairing_code_done_title else R.string.pairing_code_title),
                style = MaterialTheme.typography.headlineMedium,
                color = PeeringColors.ink,
                modifier = Modifier.arrive(),
            )
            when (screen) {
                is PairingCodeScreen.Failed -> Failure(screen, actions)
                else -> Steps(screen, actions)
            }
        }
        if (screen !is PairingCodeScreen.Failed && screen !is PairingCodeScreen.Done) {
            FooterLink(stringResource(R.string.pairing_code_cancel), actions.onCancel)
        }
    }
}

@Composable
private fun Steps(screen: PairingCodeScreen, actions: PairingActions) {
    val entering = screen as? PairingCodeScreen.EnteringCode
    val done = screen is PairingCodeScreen.Done
    val connecting = screen is PairingCodeScreen.Connecting
    Column {
        GuideStepRow(1, if (connecting) GuideStepState.Current else GuideStepState.Done, stringResource(R.string.pairing_step_found), Modifier.arrive(0)) {
            if (connecting) {
                StepDetail(stringResource(R.string.pairing_step_connecting_detail))
                PeeringSpinner(color = PeeringColors.ink)
            } else {
                StepDetail(stringResource(R.string.pairing_step_found_detail))
            }
        }
        GuideStepRow(2, if (entering != null) GuideStepState.Current else if (connecting) GuideStepState.Pending else GuideStepState.Done, stringResource(R.string.pairing_step_code), Modifier.arrive(60)) {
            if (entering != null) EnteringCode(entering, actions) else if (!connecting) StepDetail(stringResource(R.string.pairing_step_code_done))
        }
        GuideStepRow(
            3,
            when {
                entering != null || connecting -> GuideStepState.Pending
                done -> GuideStepState.Done
                else -> GuideStepState.Current
            },
            stringResource(R.string.pairing_step_approve),
            Modifier.arrive(120),
        ) {
            if (screen == PairingCodeScreen.Waiting) {
                StepDetail(stringResource(R.string.pairing_code_waiting))
                PeeringSpinner(color = PeeringColors.ink)
            }
        }
        GuideStepRow(4, if (done) GuideStepState.Done else GuideStepState.Pending, stringResource(R.string.pairing_step_connected), Modifier.arrive(180), isLast = true) {
            if (done) StepDetail(stringResource(R.string.pairing_code_done)) else StepDetail(stringResource(R.string.pairing_step_connected_detail))
            if (done) PrimaryButton(stringResource(R.string.pairing_code_back), actions.onFinished, Modifier.padding(top = 8.dp))
        }
    }
}

@Composable
private fun ColumnScope.EnteringCode(screen: PairingCodeScreen.EnteringCode, actions: PairingActions) {
    StepDetail(stringResource(R.string.pairing_code_detail))
    PairingCodeCells(attempts = screen.attempts, wrong = screen.error != null, onComplete = actions.onDigitsEntered)
    if (screen.error != null) {
        val left = (MAX_PAIRING_ATTEMPTS - screen.attempts).coerceAtLeast(1)
        Text(
            stringResource(R.string.pairing_code_wrong) + " " + pluralStringResource(R.plurals.pairing_code_tries_left, left, left),
            style = PeeringText.footnote,
            color = PeeringColors.danger,
        )
    }
    if (actions.onScan != null) {
        Row(
            Modifier.fillMaxWidth().height(40.dp).tappable(actions.onScan),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(AppIcons.qrScanner, null, tint = PeeringColors.muted, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.pairing_code_scan), style = PeeringText.subheadlineMedium, color = PeeringColors.muted)
        }
    }
}

@Composable
private fun Failure(screen: PairingCodeScreen.Failed, actions: PairingActions) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        IconTile(AppIcons.warning, size = 56.dp)
        FailureNotice(screen.message.text(), screen.details)
        PrimaryButton(stringResource(R.string.pairing_code_back), actions.onFinished)
    }
}

@Composable
private fun FooterLink(text: String, onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 8.dp), contentAlignment = Alignment.Center) {
        TextButton(onClick = onClick, colors = ButtonDefaults.textButtonColors(contentColor = PeeringColors.muted)) { Text(text) }
    }
}

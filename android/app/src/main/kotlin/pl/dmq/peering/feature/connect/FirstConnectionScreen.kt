package pl.dmq.peering.feature.connect

import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.TextButton
import androidx.compose.animation.AnimatedVisibility
import pl.dmq.peering.ui.kit.Motion
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.Failure
import pl.dmq.peering.feature.pairing.PairingActions
import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.ui.kit.GuideStepRow
import pl.dmq.peering.ui.kit.GuideStepState
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.StepDetail
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop

/**
 * Everything between the tour and a first picture as one column that ticks down its own list: install, open, choose a
 * computer, enter the code, approve. Once a computer is chosen the code and the approval happen in the same column.
 */
@Composable
fun FirstConnectionScreen(
    state: ConnectUiState,
    actions: ConnectActions,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
    pairing: PairingCodeScreen? = null,
    pairingActions: PairingActions? = null,
    hostName: String? = null,
) {
    val found = state.listing.nearby
    val inPairing = pairing != null && pairingActions != null
    val ticked = rememberFirstConnectionTicks(found)
    var entryOpen by rememberSaveable { mutableStateOf(false) }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
    Column(modifier.fillMaxSize().peeringBackdrop().windowInsetsPadding(WindowInsets.statusBars).imePadding()) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 22.dp).padding(top = 48.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            FirstConnectionHeader(pairing)
            if (pairing is PairingCodeScreen.Failed && pairingActions != null) {
                Failure(pairing, pairingActions)
            } else {
                FirstConnectionSteps(
                    found, ticked, inPairing, pairing, pairingActions, hostName, actions,
                    onEnterId = { entryOpen = true },
                    onEnterAddress = { addressOpen = true },
                )
            }
        }
        FirstConnectionFooter(pairing, pairingActions, onSkip)
    }
    ConnectEntrySheets(state, actions, entryOpen, addressOpen, { entryOpen = it }, { addressOpen = it })
}

@Composable
private fun rememberFirstConnectionTicks(found: List<HostRow>): Int {
    var ticked by remember { mutableIntStateOf(0) }
    LaunchedEffect(found.isEmpty()) {
        if (found.isEmpty()) {
            ticked = 0
        } else {
            delay(700)
            ticked = 1
            delay(450)
            ticked = 2
        }
    }
    return ticked
}

@Composable
private fun FirstConnectionHeader(pairing: PairingCodeScreen?) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(if (pairing == PairingCodeScreen.Done) R.string.pairing_code_done_title else R.string.first_title), style = PeeringText.display(size = 32f, tracking = -1f, lineHeight = 36f), color = PeeringColors.ink)
        StepDetail(stringResource(R.string.first_subtitle))
    }
}

@Composable
private fun FirstConnectionSteps(
    found: List<HostRow>,
    ticked: Int,
    inPairing: Boolean,
    pairing: PairingCodeScreen?,
    pairingActions: PairingActions?,
    hostName: String?,
    actions: ConnectActions,
    onEnterId: () -> Unit,
    onEnterAddress: () -> Unit,
) {
    Column {
        val installed = if (inPairing) 2 else ticked
        GuideStepRow(1, if (installed >= 1) GuideStepState.Done else GuideStepState.Current, stringResource(R.string.first_step_install), Modifier) {
            if (installed < 1) InstallLink()
        }
        GuideStepRow(2, if (installed >= 2) GuideStepState.Done else GuideStepState.Current, stringResource(R.string.first_step_open), Modifier) {
            if (installed < 2) StepDetail(stringResource(R.string.first_step_open_detail))
        }
        if (pairing != null && pairingActions != null) {
            PairingSteps(pairing, pairingActions, hostName)
        } else {
            val steps = firstConnectionSteps(null, listReady = ticked >= 2)
            GuideStepRow(3, steps.choose, stringResource(R.string.first_step_choose), Modifier) {
                ChooseContent(found, ticked >= 2, actions, onEnterId = onEnterId, onEnterAddress = onEnterAddress)
            }
            GuideStepRow(4, steps.code, stringResource(R.string.pairing_step_code), Modifier)
            GuideStepRow(5, steps.approve, stringResource(R.string.pairing_step_approve), Modifier, isLast = true)
        }
    }
}

@Composable
private fun ColumnScope.FirstConnectionFooter(pairing: PairingCodeScreen?, pairingActions: PairingActions?, onSkip: () -> Unit) {
    val footer = when {
        pairing == null -> R.string.first_later to onSkip
        pairingActions != null && pairing !is PairingCodeScreen.Failed && pairing != PairingCodeScreen.Done ->
            R.string.pairing_code_cancel to pairingActions.onCancel
        else -> null
    }
    if (footer != null) {
        TextButton(
            onClick = footer.second,
            modifier = Modifier.align(Alignment.CenterHorizontally).padding(bottom = 8.dp),
            colors = ButtonDefaults.textButtonColors(contentColor = PeeringColors.muted),
        ) { Text(stringResource(footer.first)) }
    }
}

@Composable
private fun ChooseContent(found: List<HostRow>, ready: Boolean, actions: ConnectActions, onEnterId: () -> Unit, onEnterAddress: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (found.isEmpty() || !ready) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PeeringSpinner(color = PeeringColors.ink)
                Spacer(Modifier.width(10.dp))
                StepDetail(stringResource(R.string.first_looking))
            }
        }
        AnimatedVisibility(found.isNotEmpty() && ready, enter = Motion.enter, exit = Motion.leave) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                found.forEach { host -> NearbyChoice(host) { actions.onPair(host.id) } }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val scan = actions.onScan
            if (scan != null) {
                Alternative(stringResource(R.string.first_scan_qr), AppIcons.qrScanner, scan, Modifier.weight(1f))
            } else {
                Alternative(stringResource(R.string.first_enter_id), AppIcons.number, onEnterId, Modifier.weight(1f))
            }
            Alternative(stringResource(R.string.first_enter_address), AppIcons.keyboard, onEnterAddress, Modifier.weight(1f))
        }
    }
}

@Composable
private fun NearbyChoice(host: HostRow, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).rowSurface().tappable(onClick).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(AppIcons.computer, null, tint = PeeringColors.ink, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(host.name ?: stringResource(R.string.connect_unnamed_host), style = PeeringText.subheadlineSemibold.copy(fontWeight = FontWeight.SemiBold), color = PeeringColors.ink)
            Text(stringResource(R.string.first_tap_to_connect), style = PeeringText.caption, color = PeeringColors.muted)
        }
        Icon(AppIcons.chevronRight, null, tint = PeeringColors.muted, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun Alternative(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit, modifier: Modifier) {
    Row(
        modifier.heightIn(min = 44.dp).rowSurface().tappable(onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = PeeringColors.ink, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, style = PeeringText.footnote.copy(fontWeight = FontWeight.Medium), color = PeeringColors.ink)
    }
}

@Composable
private fun InstallLink() {
    val uri = LocalUriHandler.current
    val clipboard = LocalClipboardManager.current
    val address = stringResource(R.string.tour_download_address)
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(2_000)
            copied = false
        }
    }
    Row(Modifier.fillMaxWidth().rowSurface(), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).heightIn(min = 48.dp).tappable({ uri.openUri("https://getpeering.app/download") }).padding(start = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(address, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, modifier = Modifier.weight(1f), maxLines = 1)
            Icon(AppIcons.openExternal, null, tint = PeeringColors.muted, modifier = Modifier.padding(horizontal = 8.dp).size(16.dp))
        }
        Box(
            Modifier.size(48.dp).tappable({
                clipboard.setText(AnnotatedString(address))
                copied = true
            }),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (copied) AppIcons.check else AppIcons.copy,
                stringResource(if (copied) R.string.tour_download_copied else R.string.tour_download_copy),
                tint = if (copied) PeeringColors.ink else PeeringColors.muted,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

package pl.dmq.peering.feature.connect

import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.TextButton
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.ui.kit.GuideStepRow
import pl.dmq.peering.ui.kit.GuideStepState
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.StepDetail
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.arrive
import pl.dmq.peering.ui.theme.peeringBackdrop

/**
 * Everything between the tour and a first picture as one column that ticks down its own list: install, open, choose a
 * computer. The code and the approval continue on the pairing screen the choice opens.
 */
@Composable
fun FirstConnectionScreen(state: ConnectUiState, actions: ConnectActions, onSkip: () -> Unit, modifier: Modifier = Modifier) {
    val found = state.listing.nearby
    var ticked by remember { mutableIntStateOf(0) }
    var entryOpen by rememberSaveable { mutableStateOf(false) }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
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
    Column(modifier.fillMaxSize().peeringBackdrop().windowInsetsPadding(WindowInsets.statusBars)) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 22.dp).padding(top = 48.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            Column(Modifier.arrive(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.first_title), style = PeeringText.display(size = 32f, tracking = -1f, lineHeight = 36f), color = PeeringColors.ink)
                StepDetail(stringResource(R.string.first_subtitle))
            }
            Column {
                GuideStepRow(1, if (ticked >= 1) GuideStepState.Done else GuideStepState.Current, stringResource(R.string.first_step_install), Modifier.arrive(60)) {
                    if (ticked < 1) InstallLink()
                }
                GuideStepRow(2, if (ticked >= 2) GuideStepState.Done else GuideStepState.Current, stringResource(R.string.first_step_open), Modifier.arrive(120)) {
                    if (ticked < 2) StepDetail(stringResource(R.string.first_step_open_detail))
                }
                GuideStepRow(3, if (ticked >= 2) GuideStepState.Current else GuideStepState.Pending, stringResource(R.string.first_step_choose), Modifier.arrive(180)) {
                    ChooseContent(found, ticked >= 2, actions, onEnterId = { entryOpen = true }, onEnterAddress = { addressOpen = true })
                }
                GuideStepRow(4, GuideStepState.Pending, stringResource(R.string.pairing_step_code), Modifier.arrive(240))
                GuideStepRow(5, GuideStepState.Pending, stringResource(R.string.pairing_step_approve), Modifier.arrive(300), isLast = true)
            }
        }
        TextButton(
            onClick = onSkip,
            modifier = Modifier.align(Alignment.CenterHorizontally).padding(bottom = 8.dp),
            colors = ButtonDefaults.textButtonColors(contentColor = PeeringColors.muted),
        ) { Text(stringResource(R.string.first_later)) }
    }
    if (entryOpen) {
        HostIdEntrySheet(
            state = state.entry,
            onTextChanged = actions.onEntryTextChanged,
            onSubmit = actions.onEntrySubmit,
            onScan = actions.onScan?.let { scan -> { entryOpen = false; scan() } },
            onDismiss = { entryOpen = false },
        )
    }
    if (addressOpen) {
        ManualAddressSheet(onConnect = { host, port -> addressOpen = false; actions.onConnectAddress(host, port) }, onDismiss = { addressOpen = false })
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
        AnimatedVisibility(found.isNotEmpty() && ready) {
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

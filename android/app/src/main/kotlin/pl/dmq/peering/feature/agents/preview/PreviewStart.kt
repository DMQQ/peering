package pl.dmq.peering.feature.agents.preview

import pl.dmq.peering.ui.kit.tonalCard
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.PreviewFailure

/** Before a page is open: the servers answering on the computer, one tap each, or an address typed above. */
@Composable
fun PreviewStart(ui: PreviewUi, onOpenPort: (Int) -> Unit, onLookAgain: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        EmptyState(
            icon = AppIcons.globe,
            title = stringResource(R.string.preview_start_title),
            body = stringResource(R.string.preview_start_detail),
            modifier = Modifier.padding(top = 28.dp),
        )
        Servers(ui, onOpenPort, onLookAgain)
        Text(
            stringResource(R.string.preview_note_live_reload),
            style = PeeringText.caption,
            color = PeeringColors.tertiary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun Servers(ui: PreviewUi, onOpenPort: (Int) -> Unit, onLookAgain: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(if (ui.detectedPorts.isEmpty() && !ui.probing) R.string.preview_found_none else R.string.preview_found_some),
                style = PeeringText.captionSemibold.copy(fontWeight = FontWeight.Medium),
                color = PeeringColors.muted,
                modifier = Modifier.weight(1f),
            )
            if (ui.probing) {
                CircularProgressIndicator(color = PeeringColors.muted, strokeWidth = 2.dp, modifier = Modifier.size(12.dp))
            } else {
                Text(
                    stringResource(R.string.preview_look_again),
                    style = PeeringText.captionSemibold.copy(fontWeight = FontWeight.Medium),
                    color = PeeringColors.accent,
                    modifier = Modifier.clickable(role = Role.Button, onClick = onLookAgain).padding(vertical = 8.dp),
                )
            }
        }
        if (ui.detectedPorts.isNotEmpty()) {
            val shape = peeringShapes.small
            Column(Modifier.fillMaxWidth().tonalCard(shape)) {
                ui.detectedPorts.forEachIndexed { index, port ->
                    if (index > 0) HorizontalDivider(color = PeeringColors.hairline)
                    ServerRow(port) { onOpenPort(port) }
                }
            }
        }
    }
}

@Composable
private fun ServerRow(port: Int, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(54.dp).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.preview_port_label, port), style = PeeringText.headline.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold), color = PeeringColors.ink)
        Text("localhost:$port", style = PeeringText.footnote.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp), color = PeeringColors.muted, modifier = Modifier.weight(1f))
        Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(18.dp))
    }
}

/** A page that could not be opened, with the reason in words and the way to try again. */
@Composable
fun PreviewFailureView(failure: PreviewFailure?, onRetry: () -> Unit) {
    val (title, detail) = failureText(failure)
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 80.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        EmptyState(icon = AppIcons.warning, title = title, body = detail)
        InkButton(onClick = onRetry) { Text(stringResource(R.string.preview_try_again)) }
    }
}

@Composable
private fun failureText(failure: PreviewFailure?): Pair<String, String> {
    val title = when (failure) {
        PreviewFailure.NOT_LISTENING -> R.string.preview_fail_not_listening
        PreviewFailure.DISCONNECTED -> R.string.preview_fail_disconnected
        PreviewFailure.TIMED_OUT -> R.string.preview_fail_timed_out
        else -> R.string.preview_fail_other
    }
    return stringResource(title) to stringResource(previewFailureDetail(failure))
}

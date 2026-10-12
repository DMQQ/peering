package pl.dmq.peering.feature.connect

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.HostIdEntryPanel
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringBackdrop

/** The Connect screen. Intents go to [presenter]; the wiring owns the presenter and what connecting and pairing do. */
@Composable
fun ConnectRoute(
    presenter: ConnectPresenter,
    modifier: Modifier = Modifier,
    onScanRequested: (() -> Unit)? = null,
) {
    val state by presenter.state.collectAsState()
    Column(
        modifier = modifier
            .fillMaxSize()
            .peeringBackdrop()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Header()
        HostSection(
            heading = stringResource(R.string.connect_paired_heading),
            rows = state.listing.paired,
            onOpen = presenter::connect,
            onForget = presenter::requestForget,
        )
        HostSection(
            heading = stringResource(R.string.connect_nearby_heading),
            rows = state.listing.nearby,
            onOpen = presenter::pair,
            emptyContent = {
                Text(
                    text = stringResource(R.string.connect_nearby_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = PeeringColors.faint,
                )
                OutlinedButton(onClick = presenter::searchAgain) {
                    Text(stringResource(R.string.connect_search_again))
                }
            },
        )
        state.message?.let { message ->
            Text(
                text = stringResource(message.messageRes()),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
        }
        HostIdEntryPanel(
            presenter = presenter.entry,
            onScanRequested = onScanRequested,
        )
    }
    if (state.forgetTarget != null) {
        ForgetDialog(onConfirm = presenter::confirmForget, onDismiss = presenter::cancelForget)
    }
}

@Composable
private fun Header() {
    Column {
        Text(
            text = stringResource(R.string.connect_title),
            style = MaterialTheme.typography.headlineLarge,
            color = PeeringColors.ink,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = stringResource(R.string.connect_detail),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
    }
}

@Composable
private fun HostSection(
    heading: String,
    rows: List<HostRow>,
    onOpen: (String) -> Unit,
    onForget: ((String) -> Unit)? = null,
    emptyContent: (@Composable () -> Unit)? = null,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            text = heading,
            style = MaterialTheme.typography.titleSmall,
            color = PeeringColors.muted,
        )
        if (rows.isEmpty() && emptyContent != null) emptyContent()
        rows.forEach { row ->
            HostCard(
                row = row,
                onOpen = { onOpen(row.id) },
                onForget = onForget?.let { forget -> { forget(row.id) } },
            )
        }
    }
}

@Composable
private fun HostCard(row: HostRow, onOpen: () -> Unit, onForget: (() -> Unit)?) {
    OutlinedPanel(modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(row.status)
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = row.name ?: stringResource(R.string.connect_unnamed_host),
                    style = MaterialTheme.typography.titleSmall,
                    color = PeeringColors.ink,
                )
                Text(
                    text = stringResource(row.status.labelRes()),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.muted,
                )
            }
            onForget?.let {
                TextButton(onClick = it) {
                    Text(
                        text = stringResource(R.string.connect_forget),
                        color = PeeringColors.danger,
                    )
                }
            }
        }
    }
}

@Composable
private fun ForgetDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = PeeringColors.backdrop,
        title = { Text(stringResource(R.string.connect_forget_title)) },
        text = { Text(stringResource(R.string.connect_forget_text)) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.connect_forget_confirm), color = PeeringColors.danger)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.connect_cancel), color = PeeringColors.ink)
            }
        },
    )
}

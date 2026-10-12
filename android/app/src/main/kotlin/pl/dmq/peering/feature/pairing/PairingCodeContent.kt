package pl.dmq.peering.feature.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.controller.MAX_PAIRING_ATTEMPTS
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.InkButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.arrive

/** The pairing steps, one calm thing at a time: six cells for the code the computer shows, then the wait. */
@Composable
fun PairingCodeContent(screen: PairingCodeScreen, actions: PairingActions, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().imePadding().padding(horizontal = 22.dp).padding(top = 16.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.arrive()) {
            Text(
                text = stringResource(R.string.pairing_code_title),
                style = MaterialTheme.typography.headlineLarge,
                color = PeeringColors.ink,
            )
            if (screen is PairingCodeScreen.EnteringCode) {
                Text(
                    text = stringResource(R.string.pairing_code_detail),
                    style = MaterialTheme.typography.bodyMedium,
                    color = PeeringColors.muted,
                )
            }
        }
        when (screen) {
            is PairingCodeScreen.EnteringCode -> EnteringCode(screen, actions)
            PairingCodeScreen.Waiting -> Waiting(actions)
            PairingCodeScreen.Done -> Outcome(
                icon = { IconTile(Icons.Filled.Check, size = 56.dp) },
                text = stringResource(R.string.pairing_code_done),
                color = PeeringColors.ink,
                actions = actions,
            )
            is PairingCodeScreen.Failed -> Outcome(
                icon = { IconTile(Icons.Filled.ErrorOutline, size = 56.dp) },
                text = screen.message.text(),
                color = PeeringColors.danger,
                actions = actions,
            )
            PairingCodeScreen.Cancelled -> Unit
        }
    }
}

@Composable
private fun ColumnScope.EnteringCode(screen: PairingCodeScreen.EnteringCode, actions: PairingActions) {
    PairingCodeCells(
        attempts = screen.attempts,
        wrong = screen.error != null,
        onComplete = actions.onDigitsEntered,
        modifier = Modifier.arrive(delayMillis = 90).padding(top = 8.dp),
    )
    if (screen.error != null) {
        val left = (MAX_PAIRING_ATTEMPTS - screen.attempts).coerceAtLeast(1)
        Text(
            text = stringResource(R.string.pairing_code_wrong) + " " +
                pluralStringResource(R.plurals.pairing_code_tries_left, left, left),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.danger,
        )
    }
    Spacer(Modifier.weight(1f))
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.arrive(delayMillis = 160)) {
        if (actions.onScan != null) {
            TextButton(onClick = actions.onScan, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.pairing_code_scan), color = PeeringColors.ink)
            }
        }
        CancelButton(actions)
    }
}

@Composable
private fun ColumnScope.Waiting(actions: PairingActions) {
    Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            CircularProgressIndicator(color = PeeringColors.ink, strokeWidth = 2.dp, modifier = Modifier.size(32.dp))
            Text(
                text = stringResource(R.string.pairing_code_waiting),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
                textAlign = TextAlign.Center,
            )
        }
    }
    CancelButton(actions)
}

@Composable
private fun ColumnScope.Outcome(icon: @Composable () -> Unit, text: String, color: Color, actions: PairingActions) {
    Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            icon()
            Text(text, style = MaterialTheme.typography.bodyLarge, color = color, textAlign = TextAlign.Center)
        }
    }
    InkButton(onClick = actions.onFinished, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.pairing_code_back))
    }
}

@Composable
private fun CancelButton(actions: PairingActions) {
    TextButton(onClick = actions.onCancel, modifier = Modifier.fillMaxWidth().height(44.dp)) {
        Text(stringResource(R.string.pairing_code_cancel), color = PeeringColors.muted)
    }
}

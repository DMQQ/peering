package pl.dmq.peering.feature.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringBackdrop

/** The code comparison step. Calls [onFinished] once the pairing is done, failed, or cancelled. */
@Composable
fun PairingCodeRoute(
    presenter: PairingCodePresenter,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    onScanRequested: (() -> Unit)? = null,
) {
    val screen by presenter.state.collectAsState()
    LaunchedEffect(screen) {
        if (screen == PairingCodeScreen.Cancelled) onFinished()
    }
    Column(
        modifier = modifier
            .fillMaxSize()
            .peeringBackdrop()
            .padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Text(
            text = stringResource(R.string.pairing_code_title),
            style = MaterialTheme.typography.headlineSmall,
            color = PeeringColors.ink,
        )
        when (val current = screen) {
            is PairingCodeScreen.Comparing -> Comparing(current.code, presenter, onScanRequested)
            PairingCodeScreen.Waiting -> Waiting(presenter)
            PairingCodeScreen.Done -> Finished(
                text = stringResource(R.string.pairing_code_done),
                color = PeeringColors.added,
                onFinished = onFinished,
            )
            is PairingCodeScreen.Failed -> Finished(
                text = current.message.text(),
                color = PeeringColors.danger,
                onFinished = onFinished,
            )
            PairingCodeScreen.Cancelled -> Unit
        }
    }
}

@Composable
private fun Comparing(code: String, presenter: PairingCodePresenter, onScanRequested: (() -> Unit)?) {
    Text(
        text = stringResource(R.string.pairing_code_detail),
        style = MaterialTheme.typography.bodyMedium,
        color = PeeringColors.muted,
    )
    Text(
        text = code.chunked(3).joinToString("  "),
        style = MaterialTheme.typography.headlineLarge.copy(fontSize = 56.sp, lineHeight = 64.sp, letterSpacing = 4.sp),
        fontWeight = FontWeight.Bold,
        color = PeeringColors.ink,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Button(
            onClick = { presenter.confirm(codesMatch = true) },
            colors = inkButtonColors(),
            modifier = Modifier.weight(1f),
        ) {
            Text(stringResource(R.string.pairing_code_match))
        }
        OutlinedButton(
            onClick = { presenter.confirm(codesMatch = false) },
            modifier = Modifier.weight(1f),
        ) {
            Text(stringResource(R.string.pairing_code_mismatch), color = PeeringColors.ink)
        }
    }
    if (onScanRequested != null) {
        OutlinedButton(onClick = onScanRequested, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.pairing_code_scan), color = PeeringColors.ink)
        }
    }
    CancelButton(presenter)
}

@Composable
private fun Waiting(presenter: PairingCodePresenter) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(color = PeeringColors.ink, strokeWidth = 2.dp)
        Spacer(Modifier.width(12.dp))
        Text(
            text = stringResource(R.string.pairing_code_waiting),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
    }
    CancelButton(presenter)
}

@Composable
private fun Finished(text: String, color: Color, onFinished: () -> Unit) {
    Text(text = text, style = MaterialTheme.typography.bodyMedium, color = color)
    Button(onClick = onFinished, colors = inkButtonColors(), modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.pairing_code_back))
    }
}

@Composable
private fun CancelButton(presenter: PairingCodePresenter) {
    TextButton(onClick = presenter::cancel, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.pairing_code_cancel), color = PeeringColors.muted)
    }
}

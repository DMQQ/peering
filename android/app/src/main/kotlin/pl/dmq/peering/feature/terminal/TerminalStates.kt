package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors

private const val TICK_MILLIS = 120L
private const val CARET_PERIOD = 1000L
private const val CARET_ON = 620L
private const val DOTS_PERIOD = 1200L
private const val DOT_STEP = 400L

/** No list yet: the computer has not answered. */
@Composable
fun TerminalLoading(waitingForConnection: Boolean, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PeeringSpinner()
            Text(
                stringResource(if (waitingForConnection) R.string.terminal_reconnecting else R.string.terminal_loading),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
            )
        }
    }
}

/** The list came back empty. */
@Composable
fun TerminalEmpty(onNew: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        EmptyState(
            icon = TerminalGlyphs.terminal,
            title = stringResource(R.string.terminal_empty_title),
            body = stringResource(R.string.terminal_empty_body),
            action = { QuietButton(onClick = onNew) { Text(stringResource(R.string.terminal_new)) } },
        )
    }
}

/** A prompt with a blinking caret, so a shell still starting cannot be mistaken for a dead one. */
@Composable
fun TerminalStarting(modifier: Modifier = Modifier) {
    var now by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(TICK_MILLIS)
            now += TICK_MILLIS
        }
    }
    val dots = (now % DOTS_PERIOD / DOT_STEP).toInt() + 1
    val label = stringResource(R.string.terminal_starting)
    Box(modifier.fillMaxSize().semantics(mergeDescendants = true) { contentDescription = label }, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(13.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("❯", color = PeeringColors.accent, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                val caret = if (now % CARET_PERIOD < CARET_ON) PeeringColors.ink else androidx.compose.ui.graphics.Color.Transparent
                Box(Modifier.width(9.dp).height(16.dp).background(caret, RectangleShape))
            }
            Row {
                Text(label, color = PeeringColors.muted, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                Text(".".repeat(dots), modifier = Modifier.width(22.dp), color = PeeringColors.muted, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

/** A shell that stopped without printing anything. */
@Composable
fun TerminalNothingPrinted(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(stringResource(R.string.terminal_nothing_printed), color = PeeringColors.muted, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
    }
}

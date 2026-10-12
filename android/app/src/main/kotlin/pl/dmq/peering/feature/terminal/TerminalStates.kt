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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import pl.dmq.peering.ui.theme.displayFamily
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
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

/** The list came back empty inside a shell page: the same block as the list page, with its own way to start one. */
@Composable
fun TerminalEmpty(onNew: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically),
    ) {
        TerminalEmptyBlock()
        QuietButton(onClick = onNew) { Text(stringResource(R.string.terminal_new)) }
    }
}

/** A window with a command waiting in it, then the name and what a terminal here is. */
@Composable
fun TerminalEmptyBlock(modifier: Modifier = Modifier) {
    Column(modifier.padding(top = 14.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp)) {
        EmptyWindow()
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                stringResource(R.string.terminal_empty_title),
                color = PeeringColors.ink,
                fontFamily = displayFamily,
                fontSize = 24.sp,
                letterSpacing = (-0.6).sp,
            )
            Text(
                stringResource(R.string.terminal_empty_body),
                modifier = Modifier.padding(horizontal = 10.dp),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun EmptyWindow() {
    TerminalWindowFrame {
        TerminalWindowTitle(38.dp) { TerminalWindowDots() }
        TerminalWindowBody(Modifier.height(74.dp), horizontal = 16.dp, vertical = 16.dp, contentMinHeight = 0.dp) {
            Row(verticalAlignment = Alignment.Top) {
                Text("swift test", color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp, fontFamily = FontFamily.Monospace)
                Spacer(Modifier.width(2.dp))
                Box(Modifier.padding(top = 2.dp).size(width = 8.dp, height = 16.dp).background(Color.White.copy(alpha = 0.85f)))
            }
        }
    }
}

/** A prompt with a blinking caret, so a shell still starting cannot be mistaken for a dead one. */
@Composable
fun TerminalStarting(modifier: Modifier = Modifier) {
    val now = remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(TICK_MILLIS)
            now.longValue += TICK_MILLIS
        }
    }
    val dots by remember { derivedStateOf { (now.longValue % DOTS_PERIOD / DOT_STEP).toInt() + 1 } }
    val label = stringResource(R.string.terminal_starting)
    Box(modifier.fillMaxSize().semantics(mergeDescendants = true) { contentDescription = label }, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(13.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("❯", color = PeeringColors.accent, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                Box(
                    Modifier.size(width = 9.dp, height = 16.dp).drawBehind {
                        if (now.longValue % CARET_PERIOD < CARET_ON) drawRoundRect(Color.White, cornerRadius = CornerRadius(1.5.dp.toPx()))
                    },
                )
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

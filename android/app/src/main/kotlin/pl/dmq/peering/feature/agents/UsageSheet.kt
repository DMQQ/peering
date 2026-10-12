package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** What a chat has used and what is left, drawn only from what the CLI reported. */
@Composable
fun UsageSheet(usage: UsageUi, onDismiss: () -> Unit) {
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.agents_usage_title), scrollable = true) {
        Column(modifier = Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section(stringResource(R.string.agents_usage_context)) { ContextBlock(usage) }
            if (usage.inputTokens != null) Section(stringResource(R.string.agents_usage_chat)) { TokenRows(usage) }
            Section(stringResource(R.string.agents_usage_limits)) { LimitRows(usage.limits) }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, color = PeeringColors.muted)
        OutlinedPanel(modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { content() }
        }
    }
}

@Composable
private fun ContextBlock(usage: UsageUi) {
    val used = usage.contextUsed
    val window = usage.contextWindow
    val fraction = usage.contextFraction
    if (used == null) {
        Note(stringResource(R.string.agents_usage_context_none))
    } else if (fraction != null && window != null) {
        Text("${ContextMeter.percent(fraction)}%", style = MaterialTheme.typography.headlineSmall, color = PeeringColors.ink)
        Note(stringResource(R.string.agents_usage_tokens, ContextMeter.tokens(used), ContextMeter.tokens(window)))
        Meter(fraction, if (ContextMeter.isNearlyFull(fraction)) PeeringColors.caution else PeeringColors.ink)
    } else {
        Text(stringResource(R.string.agents_usage_tokens_only, ContextMeter.tokens(used)), style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink)
        Note(stringResource(R.string.agents_usage_window_unknown))
    }
}

@Composable
private fun TokenRows(usage: UsageUi) {
    usage.inputTokens?.let { ValueRow(stringResource(R.string.agents_usage_input), ContextMeter.tokens(it)) }
    usage.outputTokens?.let { ValueRow(stringResource(R.string.agents_usage_output), ContextMeter.tokens(it)) }
    usage.cachedTokens?.let { ValueRow(stringResource(R.string.agents_usage_cached), ContextMeter.tokens(it)) }
    usage.costUSD?.let { ValueRow(stringResource(R.string.agents_usage_cost), String.format(Locale.getDefault(), "US$ %.2f", it)) }
}

@Composable
private fun LimitRows(limits: List<LimitUi>) {
    if (limits.isEmpty()) Note(stringResource(R.string.agents_usage_limits_none))
    limits.forEach { limit ->
        ValueRow(limit.label, "${ContextMeter.percent(limit.usedFraction)}%")
        Meter(limit.usedFraction, if (limit.leftFraction < 0.2) PeeringColors.caution else PeeringColors.ink)
        limit.resetsAtUnix?.let { Note(stringResource(R.string.agents_usage_resets, resetLabel(it))) }
    }
}

private fun resetLabel(unixSeconds: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(unixSeconds * MILLIS_PER_SECOND))

private const val MILLIS_PER_SECOND = 1_000L

@Composable
private fun ValueRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
        Text(value, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.ink)
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
}

@Composable
private fun Meter(fraction: Double, color: Color) {
    LinearProgressIndicator(
        progress = { fraction.toFloat().coerceIn(0f, 1f) },
        modifier = Modifier.fillMaxWidth().height(8.dp).clip(MaterialTheme.shapes.small),
        color = color,
        trackColor = PeeringColors.hairline,
    )
}

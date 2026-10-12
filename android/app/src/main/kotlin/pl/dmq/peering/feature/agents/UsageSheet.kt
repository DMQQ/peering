package pl.dmq.peering.feature.agents

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.util.Locale
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.ui.theme.PillShape

/** What a chat has used and what is left, drawn only from what the CLI reported: a field it does not report is absent. */
@Composable
fun UsageSheet(usage: UsageUi, agentName: String, onDismiss: () -> Unit) {
    PeeringSheet(onDismiss = onDismiss, title = agentName.ifEmpty { stringResource(R.string.agents_usage_short) }, scrollable = true) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Section(stringResource(R.string.agents_usage_context)) { ContextBlock(usage) }
            if (usage.inputTokens != null) Section(stringResource(R.string.agents_usage_chat)) { TokenRows(usage) }
            Section(stringResource(R.string.agents_usage_limits)) { LimitRows(usage.limits) }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            title,
            style = PeeringText.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = PeeringColors.muted,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        val shape = peeringShapes.small
        Column(
            modifier = Modifier.fillMaxWidth().border(1.dp, PeeringColors.ink.copy(alpha = 0.14f), shape).padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
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
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("${ContextMeter.percent(fraction)}%", style = PeeringText.display(size = 28f), color = PeeringColors.ink)
            Text(stringResource(R.string.agents_usage_tokens, ContextMeter.tokens(used), ContextMeter.tokens(window)), style = PeeringText.subheadline, color = PeeringColors.muted)
        }
        Meter(fraction, if (ContextMeter.isNearlyFull(fraction)) PeeringColors.caution else PeeringColors.ink)
    } else {
        Text(stringResource(R.string.agents_usage_tokens_only, ContextMeter.tokens(used)), style = PeeringText.title3.copy(fontWeight = FontWeight.SemiBold), color = PeeringColors.ink)
        Note(stringResource(R.string.agents_usage_window_unknown))
    }
}

@Composable
private fun TokenRows(usage: UsageUi) {
    usage.inputTokens?.let { ValueRow(stringResource(R.string.agents_usage_input), ContextMeter.tokens(it)) }
    usage.outputTokens?.let { ValueRow(stringResource(R.string.agents_usage_output), ContextMeter.tokens(it)) }
    usage.cachedTokens?.let { ValueRow(stringResource(R.string.agents_usage_cached), ContextMeter.tokens(it)) }
    usage.costUSD?.let { ValueRow(stringResource(R.string.agents_usage_cost), String.format(Locale.US, "$%.2f", it)) }
}

@Composable
private fun LimitRows(limits: List<LimitUi>) {
    if (limits.isEmpty()) Note(stringResource(R.string.agents_usage_limits_none))
    limits.forEach { limit ->
        val left = limit.leftFraction
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
                Text(limit.label, style = PeeringText.subheadline, color = PeeringColors.ink)
                Text(
                    stringResource(R.string.agents_usage_percent_left, ContextMeter.percent(left)),
                    style = PeeringText.subheadlineMedium,
                    color = PeeringColors.ink,
                )
            }
            Meter(left, if (left < 0.05) PeeringColors.danger else if (left < 0.2) PeeringColors.caution else PeeringColors.ink)
            limit.resetsAtUnix?.let { Text(stringResource(R.string.agents_usage_renews, renewLabel(it)), style = PeeringText.caption, color = PeeringColors.muted) }
        }
    }
}

private fun renewLabel(unixSeconds: Long): String =
    DateUtils.getRelativeTimeSpanString(unixSeconds * 1_000L, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

@Composable
private fun ValueRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = PeeringText.subheadline, color = PeeringColors.muted)
        Text(value, style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = PeeringText.footnote, color = PeeringColors.muted)
}

/** An outlined capsule with the used part filled, at least a dot wide so a small share still shows. */
@Composable
private fun Meter(fraction: Double, color: Color) {
    val clamped = fraction.toFloat().coerceIn(0f, 1f)
    Box(Modifier.fillMaxWidth().height(8.dp).clip(PillShape).border(1.dp, PeeringColors.ink.copy(alpha = 0.2f), PillShape)) {
        Box(Modifier.fillMaxWidth(clamped).widthIn(min = 6.dp).height(8.dp).clip(PillShape).background(color))
    }
}


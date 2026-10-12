package pl.dmq.peering.feature.agents

import java.util.Locale
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import pl.dmq.peering.wire.AgentUsage
import pl.dmq.peering.wire.AgentUsageLimit

/** How full a chat's context is, for the small chip in the chat's top bar. */
object ContextMeter {
    /** From this fraction the agent is close to compacting or refusing, and the chip says so. */
    const val NEARLY_FULL = 0.8

    /** Null until both numbers are known: a window guessed wrong would show a confident, false figure. */
    fun fraction(used: Long?, window: Long?): Double? {
        if (used == null || window == null || window <= 0 || used < 0) return null
        return minOf(used.toDouble() / window, 1.0)
    }

    fun percent(fraction: Double): Int = (fraction * 100).roundToInt()

    /** "70k", "200k", "1M", "1.2M": what a chip has room for. */
    fun tokens(count: Long): String = when {
        count >= MILLION -> {
            val millions = count.toDouble() / MILLION
            if (millions == millions.roundToLong().toDouble()) "${millions.roundToLong()}M" else String.format(Locale.ROOT, "%.1fM", millions)
        }
        count >= THOUSAND -> "${(count.toDouble() / THOUSAND).roundToLong()}k"
        else -> "$count"
    }

    fun label(used: Long, window: Long): String = "${tokens(used)} / ${tokens(window)}"

    fun isNearlyFull(fraction: Double): Boolean = fraction >= NEARLY_FULL

    /** The account's five-hour window, when the CLI reported one. */
    fun fiveHour(limits: List<AgentUsageLimit>): AgentUsageLimit? = limits.firstOrNull { it.label == FIVE_HOURS }

    private const val FIVE_HOURS = "5 hours"
    private const val THOUSAND = 1_000L
    private const val MILLION = 1_000_000L
}

/** The top bar chip: context fullness and the five-hour figure, each present only when the CLI reported it. */
data class ContextChip(
    val contextLabel: String?,
    val contextFraction: Double?,
    val fiveHourPercent: Int?,
) {
    val nearlyFull: Boolean
        get() = (contextFraction?.let(ContextMeter::isNearlyFull) ?: false) || (fiveHourPercent ?: 0) >= NEARLY_FULL_PERCENT

    companion object {
        private const val NEARLY_FULL_PERCENT = 80

        fun of(usage: AgentUsage?): ContextChip? {
            usage ?: return null
            val used = usage.contextUsedTokens
            val window = usage.contextWindowTokens
            val fraction = ContextMeter.fraction(used, window)
            val label = if (fraction != null && used != null && window != null) ContextMeter.label(used, window) else null
            val fiveHour = ContextMeter.fiveHour(usage.limits)?.let { ContextMeter.percent(it.usedFraction) }
            if (label == null && fiveHour == null) return null
            return ContextChip(label, fraction, fiveHour)
        }
    }
}

/** One limit window as the usage sheet draws it. [resetsAtUnix] is seconds since the Unix epoch. */
data class LimitUi(val label: String, val usedFraction: Double, val resetsAtUnix: Long?) {
    val leftFraction: Double get() = (1 - usedFraction).coerceIn(0.0, 1.0)
}

/** What the usage sheet shows for one chat. Fields the CLI did not report stay null: never zero. */
data class UsageUi(
    val contextFraction: Double?,
    val contextUsed: Long?,
    val contextWindow: Long?,
    val inputTokens: Long?,
    val outputTokens: Long?,
    val cachedTokens: Long?,
    val costUSD: Double?,
    val limits: List<LimitUi>,
) {
    companion object {
        private const val APPLE_EPOCH_OFFSET_SECONDS = 978_307_200L

        fun of(usage: AgentUsage?): UsageUi = UsageUi(
            contextFraction = usage?.let { ContextMeter.fraction(it.contextUsedTokens, it.contextWindowTokens) },
            contextUsed = usage?.contextUsedTokens,
            contextWindow = usage?.contextWindowTokens,
            inputTokens = usage?.inputTokens,
            outputTokens = usage?.outputTokens,
            cachedTokens = usage?.cachedTokens?.takeIf { it > 0 },
            costUSD = usage?.costUSD,
            limits = usage?.limits.orEmpty().map {
                LimitUi(it.label, it.usedFraction, it.resetsAt?.let { seconds -> seconds.toLong() + APPLE_EPOCH_OFFSET_SECONDS })
            },
        )
    }
}

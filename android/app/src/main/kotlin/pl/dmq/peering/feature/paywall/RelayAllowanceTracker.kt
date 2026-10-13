package pl.dmq.peering.feature.paywall

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import pl.dmq.peering.session.ports.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * The relay time this phone has used today, for the paywall and the session overlay. Session time on a relayed path is
 * recorded in steps; the day rolls over at midnight in [zone], and the record survives relaunches in [store].
 */
class RelayAllowanceTracker(
    private val store: RelayUsageStore,
    private val clock: Clock,
    private val zone: ZoneId,
    paid: StateFlow<Boolean>,
    scope: CoroutineScope,
) {
    private var usage: DailyRelayUsage? = store.load()
    private var paidNow = paid.value

    private val mutableAllowance = MutableStateFlow(current())
    val allowance: StateFlow<RelayAllowance> = mutableAllowance.asStateFlow()

    init {
        scope.launch {
            paid.collect {
                paidNow = it
                refresh()
            }
        }
        scope.launch {
            while (true) {
                delay(REFRESH_MILLIS)
                refresh()
            }
        }
    }

    /** Records session time on a relayed path, for as long as [relayActive] is true. */
    suspend fun trackSessions(relayActive: Flow<Boolean>) {
        relayActive.collectLatest { active ->
            if (!active) return@collectLatest
            while (true) {
                delay(RECORD_EVERY_MILLIS)
                recordRelaySeconds(RECORD_EVERY_MILLIS / MILLIS_PER_SECOND)
            }
        }
    }

    /** The relay answered that the allowance is spent: the day is taken, whatever this phone counted. */
    fun relayRefusedQuota() {
        save(RelayUsageLedger.spent(today()))
    }

    /** The relay said how much is left in the window, which is truer than what this phone counted. */
    fun relayReportedRemaining(seconds: Long) {
        save(RelayUsageLedger.fromRemaining(today(), seconds))
    }

    /** Publishes the allowance as of now, so a day that has just rolled over shows as unused. */
    fun refresh() {
        mutableAllowance.value = current()
    }

    /** Adds [seconds] of relay time to today. */
    fun recordRelaySeconds(seconds: Long) {
        save(RelayUsageLedger.added(usage, today(), seconds))
    }

    private fun save(next: DailyRelayUsage) {
        usage = next
        store.save(next)
        refresh()
    }

    private fun current(): RelayAllowance = RelayAllowance(
        usedSeconds = RelayUsageLedger.usedOn(usage, today()),
        paid = paidNow,
    )

    private fun today(): LocalDate = Instant.ofEpochSecond(clock.unixSeconds()).atZone(zone).toLocalDate()

    private companion object {
        const val REFRESH_MILLIS = 60_000L
        const val RECORD_EVERY_MILLIS = 10_000L
        const val MILLIS_PER_SECOND = 1_000L
    }
}

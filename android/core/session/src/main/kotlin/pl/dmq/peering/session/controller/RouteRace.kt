package pl.dmq.peering.session.controller

import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration

/**
 * Runs route attempts in order. The first starts at once; each later one starts when its [Attempt.startsAfter] passes
 * or as soon as every attempt before it has failed. The first to open wins and the others are cancelled.
 */
internal class RouteRace(private val attempts: List<Attempt>) {
    class Attempt(val startsAfter: Duration?, val open: suspend () -> OpenedRoute)

    private class Outcome(val route: OpenedRoute?, val failure: ConnectFailure?)

    /**
     * Throws the first failure that retrying cannot fix (a refused quota, a version mismatch) when none opens, so a
     * timeout on the other route does not hide it, and otherwise the failure of the last attempt to fail.
     */
    suspend fun run(): OpenedRoute = coroutineScope {
        val outcomes = Channel<Outcome>(Channel.UNLIMITED)
        var started = 0
        var running = 0
        var lastFailure: ConnectFailure? = null
        var terminalFailure: ConnectFailure? = null

        fun startNext() {
            val attempt = attempts[started++]
            running++
            launch {
                val outcome = try {
                    Outcome(attempt.open(), null)
                } catch (failure: ConnectFailure) {
                    Outcome(null, failure)
                }
                if (outcomes.trySend(outcome).isFailure) outcome.route?.transport?.close()
            }
        }

        try {
            startNext()
            while (running > 0 || started < attempts.size) {
                val outcome = nextOutcome(started, running, outcomes)
                if (outcome == null) {
                    startNext()
                    continue
                }
                running--
                outcome.route?.let { return@coroutineScope it }
                lastFailure = outcome.failure
                if (terminalFailure == null && outcome.failure?.failure?.canRetry == false) terminalFailure = outcome.failure
                if (running == 0 && started < attempts.size) startNext()
            }
            throw checkNotNull(terminalFailure ?: lastFailure) { "a route race needs an attempt" }
        } finally {
            coroutineContext.cancelChildren()
            outcomes.close()
            closeUnread(outcomes)
        }
    }

    /** The next outcome, or null when the next attempt is due to start: its delay passed, or nothing is running to wait for. */
    private suspend fun nextOutcome(started: Int, running: Int, outcomes: Channel<Outcome>): Outcome? {
        val wait = attempts.getOrNull(started)?.startsAfter
        return when {
            started < attempts.size && wait != null -> withTimeoutOrNull(wait) { outcomes.receive() }
            running > 0 -> outcomes.receive()
            else -> null
        }
    }

    /** A route that opened after the winner did sits unread in the queue; nothing else would close it. */
    private fun closeUnread(outcomes: Channel<Outcome>) {
        while (true) outcomes.tryReceive().getOrNull()?.route?.transport?.close() ?: break
    }
}

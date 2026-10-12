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

    /** Throws the failure of the last attempt to fail when none opens. */
    suspend fun run(): OpenedRoute = coroutineScope {
        val outcomes = Channel<Outcome>(Channel.UNLIMITED)
        var started = 0
        var running = 0
        var lastFailure: ConnectFailure? = null

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
                val wait = attempts.getOrNull(started)?.startsAfter
                val outcome = if (started < attempts.size && wait != null) {
                    withTimeoutOrNull(wait) { outcomes.receive() }
                } else if (running > 0) {
                    outcomes.receive()
                } else {
                    null
                }
                if (outcome == null) {
                    startNext()
                    continue
                }
                running--
                outcome.route?.let { return@coroutineScope it }
                lastFailure = outcome.failure
                if (running == 0 && started < attempts.size) startNext()
            }
            throw checkNotNull(lastFailure) { "a route race needs an attempt" }
        } finally {
            outcomes.close()
            coroutineContext.cancelChildren()
        }
    }
}

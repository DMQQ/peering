package pl.dmq.peering.session.relay

import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds
import pl.dmq.peering.session.ports.Clock

/**
 * Asks the relay which paired hosts are up, while [setShown] says the Connect screen is visible. Asks at most once per
 * [PresenceTicker] interval. A failed ask leaves no host reported online, so each one reads as unknown rather than down.
 */
class PresenceWatch(
    private val relay: RelayConnect,
    private val hostIds: () -> List<String>,
    clock: Clock,
    scope: CoroutineScope,
) {
    private val shown = MutableStateFlow(false)
    private val online = MutableStateFlow<Set<String>>(emptySet())
    private val ticker = PresenceTicker(clock)

    val onlineHostIds: StateFlow<Set<String>> = online.asStateFlow()

    init {
        scope.launch { shown.collectLatest { visible -> if (visible) pollWhileShown() } }
    }

    fun setShown(visible: Boolean) {
        shown.value = visible
    }

    private suspend fun pollWhileShown() {
        while (true) {
            if (ticker.isDue()) {
                ticker.markAsked()
                online.value = askRelay()
            }
            delay(ticker.secondsUntilDue().seconds)
        }
    }

    private suspend fun askRelay(): Set<String> {
        val ids = hostIds()
        if (ids.isEmpty()) return emptySet()
        return try {
            relay.hostPresence(ids).filterValues { it }.keys
        } catch (unreachable: IOException) {
            emptySet()
        } catch (refused: RelaySessionException) {
            emptySet()
        }
    }
}

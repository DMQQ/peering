package pl.dmq.peering.session.controller

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.DiscoveryEvent
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Decides whether a session on the relay or a punched hole should be dialled again because its host is on this phone's network. */
internal class LanHandover(private val target: ConnectTarget, private val ports: SessionPorts) {
    private val policy = LanUpgradePolicy(ports.clock)

    /**
     * True when [path] is not the LAN, the target may take the local network, and discovery sees the host stay in view for
     * the settle time. Waits at most [window] for that, or for as long as the caller lets it run when [window] is null.
     * A true answer counts as an attempt, so it is not given again within the cooldown.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun worthMovingFrom(path: SessionRecord.Path, window: Duration? = DEFAULT_WINDOW): Boolean {
        if (path == SessionRecord.Path.LAN || target !is ConnectTarget.Paired) return false
        return try {
            val settled = suspend {
                ports.discovery.events()
                    .filter { event ->
                        when (event) {
                            is DiscoveryEvent.Found -> event.host.id == target.hostId
                            is DiscoveryEvent.Lost -> event.hostId == target.hostId
                        }
                    }
                    .mapLatest { event ->
                        if (event is DiscoveryEvent.Found) {
                            delay(LanUpgradePolicy.SETTLE_SECONDS.seconds)
                            true
                        } else {
                            false
                        }
                    }
                    .firstOrNull { it && policy.begin(target.hostId, path) }
            }
            if (window == null) settled() == true else withTimeoutOrNull(window + LanUpgradePolicy.SETTLE_SECONDS.seconds) { settled() } == true
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Exception) {
            ports.log.log("discovery failed while looking for a handover: ${failure.message}")
            false
        }
    }

    /**
     * Follows the path the session is on ([paths], null while it is not ready) and calls [move] once the host has stayed
     * visible on the local network while the session is carried by the relay or a punched hole, even with a picture up.
     */
    suspend fun watch(paths: Flow<SessionRecord.Path?>, move: () -> Unit) {
        paths.distinctUntilChanged().collectLatest { path ->
            if (path != null && worthMovingFrom(path, window = null)) move()
        }
    }

    private companion object {
        val DEFAULT_WINDOW = 5.seconds
    }
}

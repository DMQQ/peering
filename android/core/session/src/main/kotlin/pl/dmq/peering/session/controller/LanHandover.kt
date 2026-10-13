package pl.dmq.peering.session.controller

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.history.SessionRecord
import kotlin.time.Duration.Companion.seconds

/** Decides whether a session running over the relay should be dialled again because its host is now on this phone's network. */
internal class LanHandover(private val target: ConnectTarget, private val ports: SessionPorts) {
    /** True when [path] is the relay, the target may take the local network, and discovery sees the host within the window. */
    suspend fun worthMovingFrom(path: SessionRecord.Path): Boolean {
        if (path != SessionRecord.Path.RELAY || target !is ConnectTarget.Paired) return false
        return try {
            withTimeoutOrNull(WINDOW) { ports.discovery.hosts().first { it.id == target.hostId } } != null
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Exception) {
            ports.log.log("discovery failed while looking for a handover: ${failure.message}")
            false
        }
    }

    private companion object {
        val WINDOW = 5.seconds
    }
}

package pl.dmq.peering.session.controller

import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.Clock

/**
 * When a session carried by the relay or a punched hole should move to the Mac's own network. The move costs a short
 * interruption, so it waits until the Mac has stayed in view ([SETTLE_SECONDS]) and does not repeat for the same Mac
 * when the LAN dial keeps failing ([COOLDOWN_SECONDS]). Attempts are kept per host id, not per link, because the move
 * replaces the link.
 */
internal class LanUpgradePolicy(private val clock: Clock) {
    private val lastAttempt = mutableMapOf<String, Double>()

    /** True, and counted as an attempt, when [path] is worth leaving for the LAN. */
    fun begin(hostId: String, path: SessionRecord.Path): Boolean {
        val now = clock.monotonicSeconds()
        if (!shouldUpgrade(path, macVisibleOnLan = true, secondsSinceLastAttempt = lastAttempt[hostId]?.let { now - it })) return false
        lastAttempt[hostId] = now
        return true
    }

    companion object {
        const val SETTLE_SECONDS = 3L
        const val COOLDOWN_SECONDS = 90.0

        fun shouldUpgrade(path: SessionRecord.Path, macVisibleOnLan: Boolean, secondsSinceLastAttempt: Double?): Boolean {
            if (!macVisibleOnLan || path == SessionRecord.Path.LAN) return false
            return secondsSinceLastAttempt == null || secondsSinceLastAttempt >= COOLDOWN_SECONDS
        }
    }
}

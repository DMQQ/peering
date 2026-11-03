package pl.dmq.peering.feature.sessionmode

import pl.dmq.peering.session.ports.KeyValueStore

/** The mode each computer was last used in, so a session opens straight into it. */
class SessionModeMemory(private val store: KeyValueStore) {
    fun remembered(hostId: String?): SessionMode? =
        hostId?.let { SessionMode.fromKey(store.read(keyFor(it))) }

    fun remember(hostId: String?, mode: SessionMode) {
        if (hostId != null) store.write(keyFor(hostId), mode.key)
    }

    /** The mode to open in without asking, or null when the person should choose: a first visit, the setting that always asks, or a remembered mode this computer no longer offers. */
    fun startingMode(hostId: String?, asksEveryTime: Boolean, available: List<SessionMode>): SessionMode? {
        if (asksEveryTime) return null
        return remembered(hostId)?.takeIf { it in available }
    }

    private fun keyFor(hostId: String) = "session_mode.$hostId"
}

package pl.dmq.peering.platform.net

enum class TransportKind {
    WIFI,
    CELLULAR,
    OTHER;

    companion object {
        fun from(wifi: Boolean, cellular: Boolean): TransportKind = when {
            wifi -> WIFI
            cellular -> CELLULAR
            else -> OTHER
        }
    }
}

/** What the default network looks like now: whether it has connectivity and over which transport. */
data class NetworkSnapshot(val connected: Boolean, val transport: TransportKind?)

sealed interface NetworkChange {
    data class Available(val transport: TransportKind) : NetworkChange

    data object Lost : NetworkChange

    data class PathChanged(val transport: TransportKind) : NetworkChange
}

/**
 * Reduces snapshots to changes. A snapshot equal to the one before reports nothing, so callbacks that repeat the
 * current state, which Android sends often, do not reach the session layer as changes.
 */
class NetworkChangeMapper {
    private var last = NetworkSnapshot(connected = false, transport = null)

    fun changeFor(snapshot: NetworkSnapshot): NetworkChange? {
        val previous = last
        last = snapshot
        return when {
            snapshot == previous -> null
            !snapshot.connected -> if (previous.connected) NetworkChange.Lost else null
            !previous.connected -> snapshot.transport?.let { NetworkChange.Available(it) }
            else -> snapshot.transport?.takeIf { it != previous.transport }?.let { NetworkChange.PathChanged(it) }
        }
    }
}

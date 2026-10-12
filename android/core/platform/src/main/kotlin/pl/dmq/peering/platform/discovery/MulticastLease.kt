package pl.dmq.peering.platform.discovery

import android.net.wifi.WifiManager

/**
 * Holds the Wi-Fi multicast lock that mDNS needs on many devices while discovery runs. Counted, so two collectors
 * can overlap and the lock stays held until the last of them releases it.
 */
class MulticastLease internal constructor(private val holds: LeaseCounter) {
    constructor(wifi: WifiManager) : this(wifi.createMulticastLock(TAG).let { lock ->
        lock.setReferenceCounted(false)
        LeaseCounter(onFirst = { lock.acquire() }, onLast = { if (lock.isHeld) lock.release() })
    })

    fun acquire() = holds.acquire()

    fun release() = holds.release()

    private companion object {
        const val TAG = "pl.dmq.peering.discovery"
    }
}

/** Calls [onFirst] when the count goes from zero to one and [onLast] when it returns to zero. A release with nothing held does nothing. */
internal class LeaseCounter(private val onFirst: () -> Unit, private val onLast: () -> Unit) {
    private val lock = Any()
    private var count = 0

    fun acquire() {
        val first = synchronized(lock) { (count++ == 0) }
        if (first) onFirst()
    }

    fun release() {
        val last = synchronized(lock) {
            if (count == 0) return
            --count == 0
        }
        if (last) onLast()
    }
}

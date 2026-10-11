package pl.dmq.peering.platform.discovery

import android.net.wifi.WifiManager

/** Holds the Wi-Fi multicast lock that mDNS needs on many devices while discovery runs. */
class MulticastLease(wifi: WifiManager) {
    private val lock = wifi.createMulticastLock(TAG).apply { setReferenceCounted(false) }

    fun acquire() {
        if (!lock.isHeld) lock.acquire()
    }

    fun release() {
        if (lock.isHeld) lock.release()
    }

    private companion object {
        const val TAG = "pl.dmq.peering.discovery"
    }
}

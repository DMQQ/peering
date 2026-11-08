package pl.dmq.peering.platform.net

import android.net.wifi.WifiManager

/**
 * Asks the Wi-Fi radio to stay awake for latency while held. Without it an idle radio sleeps between packets, and a
 * ping over it measured 8 ms at best and 70 ms on average with spikes past 400 ms. Android honours it only while the
 * app is on screen, which is when a remote session is being used.
 */
class WifiLatencyLock(wifi: WifiManager) {
    private val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, TAG).apply { setReferenceCounted(false) }

    fun acquire() {
        if (!lock.isHeld) lock.acquire()
    }

    fun release() {
        if (lock.isHeld) lock.release()
    }

    private companion object {
        const val TAG = "pl.dmq.peering.session"
    }
}

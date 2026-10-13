package pl.dmq.peering.platform.net

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Follows the default network. Android reports a switch as a new network followed by the loss of the old one, so only
 * events for the network currently in use count. Callbacks arrive on one thread, which is what the mapper relies on.
 */
class NetworkWatcher(private val connectivity: ConnectivityManager) {
    fun isOnline(): Boolean = connectivity.activeNetwork != null

    fun changes(): Flow<NetworkChange> = callbackFlow {
        val mapper = NetworkChangeMapper()
        var current: Network? = null

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                current = network
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (network != current) return
                val transport = TransportKind.from(
                    wifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                    cellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                )
                report(mapper.changeFor(NetworkSnapshot(connected = true, transport = transport, networkId = network.networkHandle)))
            }

            override fun onLost(network: Network) {
                if (network != current) return
                current = null
                report(mapper.changeFor(NetworkSnapshot(connected = false, transport = null)))
            }

            private fun report(change: NetworkChange?) {
                if (change != null) trySend(change)
            }
        }

        connectivity.registerDefaultNetworkCallback(callback)
        awaitClose { connectivity.unregisterNetworkCallback(callback) }
    }
}

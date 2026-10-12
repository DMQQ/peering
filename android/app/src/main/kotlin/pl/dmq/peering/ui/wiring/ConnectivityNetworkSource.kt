package pl.dmq.peering.ui.wiring

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import pl.dmq.peering.feature.connect.NetworkSource

/** Watches for a Wi-Fi or Ethernet network, the only kinds a Mac's discovery broadcast reaches. */
internal class ConnectivityNetworkSource(context: Context) : NetworkSource {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    override fun onLocalNetwork(): Flow<Boolean> = callbackFlow {
        val available = mutableSetOf<Network>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(available) { available += network }
                trySend(true)
            }

            override fun onLost(network: Network) {
                val any = synchronized(available) { available -= network; available.isNotEmpty() }
                trySend(any)
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build()
        trySend(false)
        connectivity.registerNetworkCallback(request, callback)
        awaitClose { connectivity.unregisterNetworkCallback(callback) }
    }.distinctUntilChanged()
}

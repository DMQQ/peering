package pl.dmq.peering.platform.discovery

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.PeerAddress
import kotlin.coroutines.resume

/**
 * Browses `_remotedesktop._tcp` over NsdManager. Resolution runs one service at a time, because NsdManager refuses a
 * second resolve while one is pending. A host is emitted again only when its collapsed entry changes.
 */
class NsdDiscovery(
    private val nsd: NsdManager,
    private val multicast: MulticastLease,
) : Discovery {
    override fun hosts(): Flow<DiscoveredHost> = callbackFlow {
        val found = Channel<NsdServiceInfo>(Channel.UNLIMITED)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                found.trySend(serviceInfo)
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                close(IllegalStateException("NSD discovery failed with code $errorCode"))
            }
        }

        multicast.acquire()
        nsd.discoverServices(HostMapper.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)

        val resolver = launch {
            val byService = mutableMapOf<String, DiscoveredHost>()
            val emitted = mutableMapOf<String, DiscoveredHost>()
            for (info in found) {
                val host = resolve(info) ?: continue
                byService[info.serviceName] = host
                for (current in HostMapper.collapse(byService.values)) {
                    if (emitted[current.id] != current) {
                        emitted[current.id] = current
                        send(current)
                    }
                }
            }
        }

        awaitClose {
            resolver.cancel()
            found.close()
            nsd.stopServiceDiscovery(listener)
            multicast.release()
        }
    }

    private suspend fun resolve(info: NsdServiceInfo): DiscoveredHost? {
        val resolved = suspendCancellableCoroutine<NsdServiceInfo?> { continuation ->
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    continuation.resume(null)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    continuation.resume(serviceInfo)
                }
            })
        } ?: return null
        val address = resolved.host?.hostAddress ?: return null
        val attributes = HostMapper.decodeAttributes(resolved.attributes)
        return HostMapper.map(resolved.serviceName, attributes, PeerAddress(address, resolved.port))
    }
}

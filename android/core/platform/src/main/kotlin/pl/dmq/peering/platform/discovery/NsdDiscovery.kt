package pl.dmq.peering.platform.discovery

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.DiscoveryEvent
import pl.dmq.peering.session.ports.PeerAddress
import kotlin.coroutines.resume

/**
 * Browses `_remotedesktop._tcp` over NsdManager. Every collection browses and resolves afresh, so nothing here is a
 * cached address. NsdManager allows one resolve at a time for the whole process, so resolves queue on [resolving] and a
 * refusal because another is active (a Samsung habit even without one) is retried after a short wait.
 */
class NsdDiscovery(
    private val nsd: NsdManager,
    private val multicast: MulticastLease,
) : Discovery {
    private val resolving = Mutex()

    override fun hosts(): Flow<DiscoveredHost> = events().filterIsInstance<DiscoveryEvent.Found>().map { it.host }

    override fun events(): Flow<DiscoveryEvent> = callbackFlow {
        val changes = Channel<ServiceChange>(Channel.UNLIMITED)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "browse started for $serviceType")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "browse stopped")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "stopping the browse failed, code $errorCode")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "service found: ${serviceInfo.serviceName}")
                changes.trySend(ServiceChange.Found(serviceInfo))
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "service lost: ${serviceInfo.serviceName}")
                changes.trySend(ServiceChange.Lost(serviceInfo.serviceName))
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "starting the browse failed, code $errorCode")
                close(IOException("NSD discovery failed with code $errorCode"))
            }
        }

        multicast.acquire()
        val started = try {
            nsd.discoverServices(HostMapper.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            true
        } catch (failure: RuntimeException) {
            Log.w(TAG, "starting the browse threw", failure)
            close(IOException("NSD discovery could not start", failure))
            false
        }

        val resolver = launch {
            val roster = ServiceRoster()
            for (change in changes) {
                val events = when (change) {
                    is ServiceChange.Found -> resolve(change.info)
                        ?.let { roster.found(change.info.serviceName, it) }
                        .orEmpty()
                    is ServiceChange.Lost -> roster.lost(change.serviceName)
                }
                for (event in events) {
                    Log.d(TAG, "emit ${describe(event)}")
                    send(event)
                }
            }
        }

        awaitClose {
            resolver.cancel()
            changes.close()
            if (started) {
                try {
                    nsd.stopServiceDiscovery(listener)
                } catch (failure: RuntimeException) {
                    Log.w(TAG, "stopping the browse threw", failure)
                }
            }
            multicast.release()
        }
    }

    private suspend fun resolve(info: NsdServiceInfo): DiscoveredHost? = resolving.withLock {
        var attempt = 0
        var host: DiscoveredHost? = null
        var settled = false
        while (!settled) {
            when (val result = withTimeoutOrNull(RESOLVE_TIMEOUT_MILLIS) { resolveOnce(info) }) {
                null -> {
                    Log.w(TAG, "resolve of ${info.serviceName} timed out")
                    settled = true
                }
                is ResolveResult.Resolved -> {
                    host = hostOf(result.info)
                    settled = true
                }
                is ResolveResult.Failed -> {
                    val wait = ResolvePolicy.retryDelayMillis(result.code, attempt)
                    Log.w(TAG, "resolve of ${info.serviceName} failed, code ${result.code}, retry in ${wait ?: "never"}")
                    if (wait == null) settled = true else delay(wait)
                    attempt++
                }
            }
        }
        host
    }

    private suspend fun resolveOnce(info: NsdServiceInfo): ResolveResult = suspendCancellableCoroutine { continuation ->
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    if (continuation.isActive) continuation.resume(ResolveResult.Failed(errorCode))
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    if (continuation.isActive) continuation.resume(ResolveResult.Resolved(serviceInfo))
                }
            })
        } catch (failure: RuntimeException) {
            Log.w(TAG, "resolving ${info.serviceName} threw", failure)
            continuation.resume(ResolveResult.Failed(THREW))
        }
    }

    private fun hostOf(resolved: NsdServiceInfo): DiscoveredHost? {
        val address = resolved.host?.hostAddress ?: return null
        val attributes = HostMapper.decodeAttributes(resolved.attributes)
        val host = HostMapper.map(resolved.serviceName, attributes, PeerAddress(address, resolved.port))
        Log.d(TAG, "resolved ${resolved.serviceName} to $address:${resolved.port}, ours: ${host != null}")
        return host
    }

    private fun describe(event: DiscoveryEvent): String = when (event) {
        is DiscoveryEvent.Found -> "found ${event.host.id} at ${event.host.address.host}:${event.host.address.port}"
        is DiscoveryEvent.Lost -> "lost ${event.hostId}"
    }

    private sealed interface ServiceChange {
        class Found(val info: NsdServiceInfo) : ServiceChange

        class Lost(val serviceName: String) : ServiceChange
    }

    private sealed interface ResolveResult {
        class Resolved(val info: NsdServiceInfo) : ResolveResult

        class Failed(val code: Int) : ResolveResult
    }

    private companion object {
        const val TAG = "PeeringDiscovery"
        const val RESOLVE_TIMEOUT_MILLIS = 10_000L
        const val THREW = -1
    }
}

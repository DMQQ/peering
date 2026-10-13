package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import pl.dmq.peering.feature.settings.TrustedHost
import pl.dmq.peering.feature.settings.TrustedHostStore
import pl.dmq.peering.session.hosts.HostDirectory
import pl.dmq.peering.session.ports.PinStore

/** The Macs this device has paired with, each named from the directory when a name is known. */
internal class PinTrustedHosts(
    private val pins: PinStore,
    private val directory: HostDirectory,
) : TrustedHostStore {
    override fun trustedHosts(): Flow<List<TrustedHost>> = directory.known.map { known ->
        pins.hostIds().map { TrustedHost(id = it, name = known[it]?.name) }
    }

    override fun forget(hostId: String): Boolean {
        val removed = pins.remove(hostId)
        if (removed) directory.forget(hostId)
        return removed
    }
}

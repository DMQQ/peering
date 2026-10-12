package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import pl.dmq.peering.feature.settings.TrustedHost
import pl.dmq.peering.feature.settings.TrustedHostStore
import pl.dmq.peering.session.ports.PinStore

/** The Macs this device has paired with. The pin store keeps no names, so each Mac is listed by its id. */
internal class PinTrustedHosts(private val pins: PinStore) : TrustedHostStore {
    override fun trustedHosts(): Flow<List<TrustedHost>> = flow {
        emit(pins.hostIds().map { TrustedHost(id = it, name = null) })
    }

    override fun forget(hostId: String): Boolean = pins.remove(hostId)
}

package pl.dmq.peering.session.testing

import pl.dmq.peering.session.ports.PinStore

/** An in-memory pin store. Set [writesSucceed] to false to make every write report failure. */
class FakePinStore(initial: Map<String, ByteArray> = emptyMap()) : PinStore {
    private val pins = initial.toMutableMap()

    var writesSucceed = true

    override fun pin(hostId: String): ByteArray? = pins[hostId]

    override fun record(hostId: String, key: ByteArray): Boolean {
        if (!writesSucceed) return false
        pins[hostId] = key.copyOf()
        return true
    }

    override fun remove(hostId: String): Boolean {
        if (!writesSucceed) return false
        pins.remove(hostId)
        return true
    }
}

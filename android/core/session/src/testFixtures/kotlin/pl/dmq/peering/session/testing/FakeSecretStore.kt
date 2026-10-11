package pl.dmq.peering.session.testing

import pl.dmq.peering.session.ports.SecretStore

/** An in-memory secret store. Set [writesSucceed] to false to make every write report failure. */
class FakeSecretStore : SecretStore {
    private val values = mutableMapOf<String, ByteArray>()

    var writesSucceed = true

    override fun get(key: String): ByteArray? = values[key]

    override fun put(key: String, value: ByteArray): Boolean {
        if (!writesSucceed) return false
        values[key] = value.copyOf()
        return true
    }

    override fun remove(key: String): Boolean {
        if (!writesSucceed) return false
        values.remove(key)
        return true
    }
}

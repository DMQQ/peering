package pl.dmq.peering.feature.terminal

import pl.dmq.peering.session.ports.KeyValueStore

class FakeKeyValueStore : KeyValueStore {
    private val values = HashMap<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String) {
        values[key] = value
    }
}

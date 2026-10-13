package pl.dmq.peering.ssh.store

import pl.dmq.peering.session.ports.KeyValueStore

/** A view of a store under its own prefix, so the SSH quick commands do not share a list with the Mac terminal's. */
class PrefixedKeyValueStore(private val inner: KeyValueStore, private val prefix: String) : KeyValueStore {
    override fun read(key: String): String? = inner.read(prefix + key)

    override fun write(key: String, value: String) = inner.write(prefix + key, value)
}

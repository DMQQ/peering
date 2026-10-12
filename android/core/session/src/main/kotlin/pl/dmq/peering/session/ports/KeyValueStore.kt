package pl.dmq.peering.session.ports

/** A small text store for values the session layer keeps across launches. */
interface KeyValueStore {
    fun read(key: String): String?

    fun write(key: String, value: String)
}

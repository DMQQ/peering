package pl.dmq.peering.session.ports

/** The outcome of reading stored bytes, which keeps "nothing there" apart from "there, but could not be read". */
sealed interface StoredRead {
    data object Absent : StoredRead

    class Found(val bytes: ByteArray) : StoredRead

    /** [permanent] when retrying cannot help (the key is gone or the bytes are damaged), false for a failure that may pass. */
    data class Unreadable(val permanent: Boolean) : StoredRead
}

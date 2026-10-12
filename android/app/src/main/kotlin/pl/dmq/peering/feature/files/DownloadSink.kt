package pl.dmq.peering.feature.files

import java.io.IOException

/** Where one download's bytes go. Writes arrive in offset order and throw [IOException] when the destination fails. */
interface DownloadSink {
    @Throws(IOException::class)
    fun write(bytes: ByteArray)

    @Throws(IOException::class)
    fun commit()

    /** Closes the destination and removes what was written, since a partial file is not a download. */
    fun discard()
}

package pl.dmq.peering.session.files

/** Sizes that bound a file transfer over the control channel, as the Mac holds itself to them. */
object TransferLimits {
    /** Raw bytes per download piece. JSON grows it to about 87 KB on the wire. */
    const val DOWNLOAD_CHUNK_BYTES = 32 * 1024

    /** Pieces requested ahead of the ones that have arrived, so a round trip is not paid once per piece. */
    const val DOWNLOAD_WINDOW = 8

    /** A larger file, or a folder whose zip comes out larger, is refused rather than filling the phone. */
    const val MAXIMUM_DOWNLOAD_BYTES = 512L * 1024 * 1024

    const val UPLOAD_CHUNK_BYTES = 32 * 1024

    const val MAXIMUM_UPLOAD_BYTES = 2L * 1024 * 1024 * 1024
}

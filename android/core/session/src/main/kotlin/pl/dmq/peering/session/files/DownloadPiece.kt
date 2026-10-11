package pl.dmq.peering.session.files

/** Bytes of a download that the platform must write at [offset] before the next request is sent. */
internal class DownloadPiece(val offset: Long, val bytes: ByteArray)

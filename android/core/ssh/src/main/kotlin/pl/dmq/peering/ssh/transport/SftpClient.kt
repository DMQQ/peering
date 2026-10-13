package pl.dmq.peering.ssh.transport

import pl.dmq.peering.wire.RemoteDirectoryEntry

class SftpListing(val path: String, val entries: List<RemoteDirectoryEntry>)

class SftpPiece(val bytes: ByteArray, val totalBytes: Long)

/** Blocking SFTP calls on one channel. Every failure is an [SshFailure.Browse] whose reason is a sentence for the user. */
interface SftpClient : AutoCloseable {
    /** [path] null means the login folder. The returned path is absolute and in the server's own spelling. */
    fun list(path: String?): SftpListing

    /** Up to [length] bytes of [path] from [offset], with the file's size. */
    fun read(path: String, offset: Long, length: Int): SftpPiece

    /** Starts replacing [path]; the sink takes pieces in order and [SftpUpload.finish] closes it. */
    fun beginWrite(path: String): SftpUpload

    fun createFile(path: String)

    fun createFolder(path: String)

    fun rename(path: String, newName: String)

    /** A folder goes with everything in it; the note says how much that was. */
    fun delete(path: String): String
}

interface SftpUpload : AutoCloseable {
    fun write(bytes: ByteArray)

    /** The size on the server after closing, read back so a truncation by a quota does not look saved. */
    fun finish(): Long
}

package pl.dmq.peering.sshj

import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.sftp.RemoteFile
import net.schmizz.sshj.sftp.RemoteResourceInfo
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.sftp.SFTPException
import pl.dmq.peering.ssh.transport.SftpClient
import pl.dmq.peering.ssh.transport.SftpListing
import pl.dmq.peering.ssh.transport.SftpPiece
import pl.dmq.peering.ssh.transport.SftpUpload
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.wire.RemoteDirectoryEntry
import java.io.IOException
import java.util.EnumSet

internal class SshjSftp(private val sftp: SFTPClient) : SftpClient {
    /** Pieces of one download are read one after another, so the handle is kept between them. */
    private var reading: Pair<String, RemoteFile>? = null

    override fun list(path: String?): SftpListing = guarded {
        val resolved = sftp.canonicalize(path ?: ".")
        SftpListing(resolved, sftp.ls(resolved).map(::entry))
    }

    override fun read(path: String, offset: Long, length: Int): SftpPiece = guarded {
        val file = handle(path)
        val total = file.length()
        val buffer = ByteArray(length)
        var filled = 0
        while (filled < length) {
            val count = file.read(offset + filled, buffer, filled, length - filled)
            if (count <= 0) break
            filled += count
        }
        SftpPiece(buffer.copyOf(filled), total)
    }

    override fun beginWrite(path: String): SftpUpload = guarded {
        val file = sftp.open(path, EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, OpenMode.TRUNC))
        object : SftpUpload {
            private var written = 0L

            override fun write(bytes: ByteArray) {
                guarded { file.write(written, bytes, 0, bytes.size) }
                written += bytes.size
            }

            override fun finish(): Long = guarded {
                file.close()
                sftp.size(path)
            }

            override fun close() {
                file.runCatching { close() }
            }
        }
    }

    override fun createFile(path: String) = guarded {
        sftp.open(path, EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, OpenMode.EXCL)).close()
    }

    override fun createFolder(path: String) = guarded { sftp.mkdir(path) }

    override fun rename(path: String, newName: String) = guarded {
        sftp.rename(path, path.substringBeforeLast('/', "") + "/" + newName)
    }

    override fun delete(path: String): String = guarded {
        if (sftp.lstat(path).type != FileMode.Type.DIRECTORY) {
            sftp.rm(path)
            return@guarded ""
        }
        val removed = removeTree(path)
        if (removed == 0) "" else "Removed the folder and the $removed items in it."
    }

    override fun close() {
        reading?.second?.runCatching { close() }
        reading = null
        sftp.runCatching { close() }
    }

    private fun handle(path: String): RemoteFile {
        reading?.takeIf { it.first == path }?.let { return it.second }
        reading?.second?.runCatching { close() }
        return sftp.open(path).also { reading = path to it }
    }

    private fun removeTree(folder: String): Int {
        var count = 0
        for (child in sftp.ls(folder)) {
            if (child.isDirectory && child.attributes.type != FileMode.Type.SYMLINK) {
                count += removeTree(child.path)
            } else {
                sftp.rm(child.path)
            }
            count++
        }
        sftp.rmdir(folder)
        return count
    }

    private fun entry(info: RemoteResourceInfo): RemoteDirectoryEntry {
        val attributes = info.attributes
        val isLink = attributes.type == FileMode.Type.SYMLINK
        val isDirectory = if (isLink) pointsToFolder(info.path) else info.isDirectory
        return RemoteDirectoryEntry(
            name = info.name,
            isDirectory = isDirectory,
            isSymlink = isLink,
            size = attributes.size,
            permissions = permissionText(attributes.mode),
            modified = attributes.mtime.takeIf { it > 0 }?.toDouble(),
        )
    }

    private fun pointsToFolder(path: String): Boolean =
        try {
            sftp.stat(path).type == FileMode.Type.DIRECTORY
        } catch (_: IOException) {
            false
        }

    /** `drwxr-xr-x`, as `ls -l` spells it, because the file screens read the execute bits from it. */
    private fun permissionText(mode: FileMode): String {
        val bits = mode.permissionsMask
        val kind = when (mode.type) {
            FileMode.Type.DIRECTORY -> 'd'
            FileMode.Type.SYMLINK -> 'l'
            else -> '-'
        }
        val triplets = listOf(Triple(0x100, 0x80, 0x40), Triple(0x20, 0x10, 0x8), Triple(0x4, 0x2, 0x1))
        return kind + triplets.joinToString("") { (r, w, x) ->
            (if (bits and r != 0) "r" else "-") + (if (bits and w != 0) "w" else "-") + (if (bits and x != 0) "x" else "-")
        }
    }

    private inline fun <T> guarded(action: () -> T): T =
        try {
            action()
        } catch (failure: SFTPException) {
            throw SshFailure.Browse(describe(failure))
        } catch (failure: IOException) {
            throw SshFailure.Browse(failure.message ?: "The server did not answer.")
        }

    private fun describe(failure: SFTPException): String = when (failure.statusCode) {
        net.schmizz.sshj.sftp.Response.StatusCode.NO_SUCH_FILE -> "That path does not exist."
        net.schmizz.sshj.sftp.Response.StatusCode.PERMISSION_DENIED -> "The server did not allow that."
        net.schmizz.sshj.sftp.Response.StatusCode.FILE_ALREADY_EXISTS -> "Something with that name already exists."
        else -> failure.message ?: "The server refused that."
    }
}

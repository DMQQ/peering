package pl.dmq.peering.imaging

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

private const val MAX_AGE_MILLIS = 24L * 60 * 60 * 1000
private const val MAX_TOTAL_BYTES = 64L * 1024 * 1024

/** Files the app hands to other apps through the file provider, kept in one folder that is pruned on every write. */
internal object SharedFiles {
    /** A file name made of the SHA-256 of [bytes], so equal content shares a file and different content never collides. */
    fun nameFor(bytes: ByteArray, extension: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) } + "." + extension
    }

    /** Writes [bytes] into [directory] under their content name and returns the file, after pruning the folder. */
    fun write(directory: File, bytes: ByteArray, extension: String, now: Long = System.currentTimeMillis()): File {
        directory.mkdirs()
        val name = nameFor(bytes, extension)
        prune(directory, keep = name, now = now)
        val file = File(directory, name)
        if (!file.exists() || file.length() != bytes.size.toLong()) publish(file, bytes)
        file.setLastModified(now)
        return file
    }

    /** Another app may open the file at any moment, so it appears whole or not at all. */
    private fun publish(file: File, bytes: ByteArray) {
        val temporary = File.createTempFile("write", ".tmp", file.parentFile)
        try {
            temporary.writeBytes(bytes)
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } finally {
            temporary.delete()
        }
    }

    /** Deletes files older than a day, then the oldest ones until the folder is under its size budget. [keep] is never deleted. */
    fun prune(directory: File, keep: String? = null, now: Long = System.currentTimeMillis()) {
        val files = directory.listFiles { file -> file.isFile && file.name != keep }.orEmpty().sortedBy { it.lastModified() }
        val (fresh, stale) = files.partition { now - it.lastModified() <= MAX_AGE_MILLIS }
        stale.forEach { it.delete() }
        var total = fresh.sumOf { it.length() }
        for (file in fresh) {
            if (total <= MAX_TOTAL_BYTES) break
            total -= file.length()
            file.delete()
        }
    }
}

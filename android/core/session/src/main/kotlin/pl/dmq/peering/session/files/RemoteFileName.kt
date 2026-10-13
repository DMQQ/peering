package pl.dmq.peering.session.files

/**
 * Name rules shared by every file operation. The phone picks a name and the Mac checks it again, so a tampered
 * client cannot name `../.ssh/authorized_keys`.
 */
object RemoteFileName {
    /** `NAME_MAX`, counted in UTF-8 bytes, because the far end answers `ENAMETOOLONG` past that. */
    const val MAXIMUM_BYTES = 255

    /** Refuses blank names, `.` and `..`, anything with a slash (a rename would become a move) and a NUL byte. */
    fun isValid(name: String): Boolean {
        if (name.isBlank() || name == "." || name == "..") return false
        if (name.contains('/') || name.contains('\u0000')) return false
        return name.toByteArray(Charsets.UTF_8).size <= MAXIMUM_BYTES
    }

    /**
     * A free name spelled like the Finder: `New Folder`, then `New Folder 2`, taking the lowest free number. The
     * comparison folds case because the file system does: `new folder` makes `New Folder` count as taken.
     */
    fun availableName(base: String, extension: String = "", existing: Iterable<String>): String {
        val taken = existing.mapTo(HashSet()) { it.lowercase() }
        val first = base + extension
        if (first.lowercase() !in taken) return first
        var number = 2
        while (true) {
            val candidate = "$base $number$extension"
            if (candidate.lowercase() !in taken) return candidate
            number++
        }
    }
}

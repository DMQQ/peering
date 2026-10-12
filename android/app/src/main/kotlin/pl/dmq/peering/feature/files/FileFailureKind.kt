package pl.dmq.peering.feature.files

/** What went wrong with a folder, read from the computer's own sentence, since the wire carries only text. */
enum class FileFailureKind {
    PERMISSION_DENIED,
    NOT_FOUND,
    OTHER,
    ;

    companion object {
        private val permissionMarks = listOf("not allowed", "permission", "denied", "not permitted")
        private val missingMarks = listOf("no longer there", "no such", "not found", "does not exist", "doesn't exist")

        fun of(message: String): FileFailureKind {
            val text = message.lowercase()
            return when {
                permissionMarks.any(text::contains) -> PERMISSION_DENIED
                missingMarks.any(text::contains) -> NOT_FOUND
                else -> OTHER
            }
        }
    }
}

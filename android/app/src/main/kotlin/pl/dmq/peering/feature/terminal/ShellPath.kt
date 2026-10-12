package pl.dmq.peering.feature.terminal

/** Paths written into a shell line. */
object ShellPath {
    /** Single quotes, nothing expands inside them; an embedded quote is written as close, escape, reopen. */
    fun quoted(path: String): String = "'" + path.replace("'", "'\\''") + "'"

    /** The line that steps a new shell into [path]. `--` because csh and tcsh still expand history inside single quotes. */
    fun changeDirectory(path: String): String = "cd -- ${quoted(path)}\r"
}

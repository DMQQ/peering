package pl.dmq.peering.session.files

/** A path written the way a shell reads it back: `My Documents` must stay one argument and `; rm -rf ~` must not become a command. */
object ShellPath {
    /**
     * Single quotes, inside which nothing expands, with an embedded quote written as close, escape, reopen. `csh` and
     * `tcsh` still expand history inside single quotes, hence `cd --` in [runCommand].
     */
    fun quoted(path: String): String = "'" + path.replace("'", "'\\''") + "'"

    /**
     * The line that runs the file at [path]: it steps into the file's folder first, because a script that names a
     * sibling file or writes output there means its own folder. The absolute path is used so the line says which file ran.
     */
    fun runCommand(path: String): String {
        val slash = path.lastIndexOf('/')
        if (slash < 0) return quoted(path)
        val folder = if (slash == 0) "/" else path.substring(0, slash)
        return "cd -- ${quoted(folder)} && ${quoted(path)}"
    }
}

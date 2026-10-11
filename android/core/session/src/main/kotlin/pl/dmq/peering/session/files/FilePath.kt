package pl.dmq.peering.session.files

/**
 * Paths as the Mac and Windows hosts spell them: POSIX shaped, with a Windows drive written as a root segment
 * (`/C:/Users/me`). Trailing slashes are never part of a path, except the root itself.
 */
object FilePath {
    /** One step of a path: [title] is what the crumb shows, [path] is the folder it opens. */
    data class Breadcrumb(val title: String, val path: String)

    private val drivePrefix = Regex("^/[A-Za-z]:")

    fun isRoot(path: String): Boolean = segments(path).isEmpty()

    /** The parent folder, or null at a root. The parent of a top-level folder is its root. */
    fun parent(path: String): String? {
        val segments = segments(path)
        if (segments.isEmpty()) return null
        return build(rootOf(path), segments.dropLast(1))
    }

    fun child(folder: String, name: String): String = build(rootOf(folder), segments(folder) + name)

    /** The last segment of [path], or the root's own title when the path is a root. */
    fun name(path: String): String = segments(path).lastOrNull() ?: rootTitle(rootOf(path))

    /** Every folder from the root down to [path], the root first. */
    fun breadcrumbs(path: String): List<Breadcrumb> {
        val root = rootOf(path)
        val segments = segments(path)
        val steps = segments.indices.map { index ->
            Breadcrumb(segments[index], build(root, segments.take(index + 1)))
        }
        return listOf(Breadcrumb(rootTitle(root), root)) + steps
    }

    private fun rootOf(path: String): String = drivePrefix.find(path)?.let { it.value + "/" } ?: "/"

    private fun rootTitle(root: String): String = if (root == "/") "/" else root.trim('/')

    private fun segments(path: String): List<String> {
        val rest = path.removePrefix(rootOf(path).trimEnd('/'))
        return rest.split('/').filter { it.isNotEmpty() }
    }

    private fun build(root: String, segments: List<String>): String =
        if (segments.isEmpty()) root else root + segments.joinToString("/")
}

package pl.dmq.peering.feature.files

/** The entry names picked in one folder. Moving to another folder forgets them, since a name means nothing there. */
internal class FileSelection {
    private var folder: String? = null
    private var names: Set<String> = emptySet()

    fun namesFor(path: String?): Set<String> = if (path == folder) names else emptySet()

    fun toggle(path: String?, name: String) {
        val base = namesFor(path)
        folder = path
        names = if (name in base) base - name else base + name
    }

    fun setAll(path: String?, all: List<String>) {
        folder = path
        names = all.toSet()
    }

    fun clear() {
        names = emptySet()
    }
}

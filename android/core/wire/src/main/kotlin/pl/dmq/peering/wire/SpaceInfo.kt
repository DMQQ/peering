package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/** One desktop as the host last saw it: a snapshot, since the host can only capture what is on the display. */
class SpacePreview(val index: Int, val width: Int, val height: Int, val jpegBase64: String) {
    val shape: Float? get() = if (width > 0 && height > 0) width.toFloat() / height else null
}

/** One display's desktops. [current] is null while a full screen app is on the display, where no desktop is current. */
data class SpaceDisplay(val displayId: Long, val count: Int, val current: Int?, val previews: List<SpacePreview>) {
    fun preview(index: Int): SpacePreview? = previews.firstOrNull { it.index == index }
}

/** Every display's desktops, as the catalogue carries them. */
data class SpaceInfo(val displays: List<SpaceDisplay>) {
    val totalCount: Int get() = displays.sumOf { it.count }

    /** More than one desktop or more than one screen: a second screen qualifies alone, since tapping its desktop moves the picture there. */
    val showsDesktops: Boolean get() = totalCount > 1 || displays.size > 1

    fun display(id: Long): SpaceDisplay? = displays.firstOrNull { it.displayId == id }

    companion object {
        /** Lenient: a host that cannot read its desktops sends none, and an older one sends a single flat display with id 0. */
        fun parse(element: JsonElement?): SpaceInfo? {
            val root = element as? JsonObject ?: return null
            val listed = root["displays"] as? JsonArray
            if (listed != null) return SpaceInfo(listed.mapNotNull { display(it as? JsonObject) })
            return display(root)?.let { SpaceInfo(listOf(it)) }
        }

        private fun display(row: JsonObject?): SpaceDisplay? {
            row ?: return null
            val count = row.int("count") ?: return null
            val previews = (row["previews"] as? JsonArray)?.mapNotNull { preview(it as? JsonObject) }.orEmpty()
            return SpaceDisplay(row.long("displayID") ?: 0L, count, row.int("current"), previews)
        }

        private fun preview(row: JsonObject?): SpacePreview? {
            row ?: return null
            val data = (row["jpegData"] as? JsonPrimitive)?.contentOrNull ?: return null
            return SpacePreview(row.int("index") ?: return null, row.int("width") ?: 0, row.int("height") ?: 0, data)
        }

        private fun JsonObject.int(name: String): Int? = (this[name] as? JsonPrimitive)?.intOrNull
        private fun JsonObject.long(name: String): Long? = (this[name] as? JsonPrimitive)?.longOrNull
    }
}

val CaptureCatalog.spaces: SpaceInfo? get() = SpaceInfo.parse(spaceInfo)

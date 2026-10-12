package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** A rectangle in the canvas's own space: (0,0) top left, (1,1) bottom right, whatever the canvas's shape. */
data class NormalizedRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    /** Half open on the far edges, so the point where two tiles meet belongs to exactly one. */
    fun contains(point: NormalizedPoint): Boolean =
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height

    fun toJson(): JsonObject = buildJsonObject {
        put("x", JsonPrimitive(x))
        put("y", JsonPrimitive(y))
        put("width", JsonPrimitive(width))
        put("height", JsonPrimitive(height))
    }

    companion object {
        fun fromJson(json: JsonObject) = NormalizedRect(
            json.getValue("x").jsonPrimitive.double,
            json.getValue("y").jsonPrimitive.double,
            json.getValue("width").jsonPrimitive.double,
            json.getValue("height").jsonPrimitive.double,
        )
    }
}

data class MosaicTile(val source: CaptureSource, val rect: NormalizedRect)

/** What a mosaic is: the canvas the host composes, the tiles on it and the redraw rate. The host trims what it will not build. */
data class MosaicLayout(val canvas: PixelSize, val tiles: List<MosaicTile>, val frameRate: Int) {
    /** The tile under [point] of the picture, or null when none holds it. */
    fun tileIndexAt(point: NormalizedPoint): Int? =
        tiles.indexOfFirst { it.rect.contains(point) }.takeIf { it >= 0 }

    fun toJson(): JsonObject = buildJsonObject {
        put("canvas", JsonArray(listOf(JsonPrimitive(canvas.width), JsonPrimitive(canvas.height))))
        put(
            "tiles",
            JsonArray(
                tiles.map { tile ->
                    buildJsonObject {
                        put("source", tile.source.toJson())
                        put("rect", tile.rect.toJson())
                    }
                },
            ),
        )
        put("frameRate", JsonPrimitive(frameRate))
    }

    companion object {
        const val MAXIMUM_TILES = 9

        /** Null when [json] is not a layout this client could have built. */
        fun fromJson(json: JsonElement): MosaicLayout? = runCatching {
            val fields = json.jsonObject
            val size = fields.getValue("canvas").jsonArray
            MosaicLayout(
                PixelSize(size[0].jsonPrimitive.double, size[1].jsonPrimitive.double),
                fields.getValue("tiles").jsonArray.map { tile ->
                    val entry = tile.jsonObject
                    MosaicTile(
                        CaptureSource.fromJson(entry.getValue("source").jsonObject),
                        NormalizedRect.fromJson(entry.getValue("rect").jsonObject),
                    )
                },
                fields.getValue("frameRate").jsonPrimitive.int,
            )
        }.getOrNull()
    }
}

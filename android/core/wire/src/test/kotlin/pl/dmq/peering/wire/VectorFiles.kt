package pl.dmq.peering.wire

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/** Reads a shared protocol vector file from docs/protocol/vectors. */
object VectorFiles {
    private val directory = File(requireNotNull(System.getProperty("peering.vectors")) { "peering.vectors is not set" })

    fun load(name: String): JsonElement = Json.parseToJsonElement(File(directory, name).readText())
}

package pl.dmq.peering.widget

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** The text form of the snapshots in SharedPreferences. A value that does not parse reads as an empty snapshot, never a crash on the home screen. */
object WidgetCodec {
    fun encode(snapshot: QuickConnectSnapshot): String = buildJsonObject {
        put("computers", buildJsonArray {
            snapshot.computers.forEach { add(buildJsonObject { put("id", it.id); put("name", it.name) }) }
        })
        put("connectedId", snapshot.connectedId)
        put("onlineIds", buildJsonArray { snapshot.onlineIds.sorted().forEach { add(JsonPrimitive(it)) } })
    }.toString()

    fun decodeQuickConnect(text: String?): QuickConnectSnapshot = parse(text) { root ->
        QuickConnectSnapshot(
            computers = root.array("computers").mapNotNull { element ->
                val item = element.jsonObject
                val id = item.string("id") ?: return@mapNotNull null
                KnownComputer(id, item.string("name").orEmpty())
            },
            connectedId = root.string("connectedId"),
            onlineIds = root.array("onlineIds").mapNotNull { it.jsonPrimitive.contentOrNull }.toSet(),
        )
    } ?: QuickConnectSnapshot()

    fun encode(snapshot: AgentsSnapshot): String = buildJsonObject {
        put("publishedAt", snapshot.publishedAtSeconds)
        put("chats", buildJsonArray {
            snapshot.chats.forEach { chat ->
                add(buildJsonObject {
                    put("id", chat.id)
                    put("hostId", chat.hostId)
                    put("title", chat.title)
                    put("folder", chat.folder)
                    put("tone", chat.tone.name)
                    put("updatedAt", chat.updatedAtSeconds)
                })
            }
        })
    }.toString()

    fun decodeAgents(text: String?): AgentsSnapshot = parse(text) { root ->
        AgentsSnapshot(
            chats = root.array("chats").mapNotNull { element ->
                val item = element.jsonObject
                val id = item.string("id") ?: return@mapNotNull null
                val tone = AgentChatTone.entries.firstOrNull { it.name == item.string("tone") } ?: return@mapNotNull null
                AgentChatEntry(
                    id = id,
                    hostId = item.string("hostId"),
                    title = item.string("title").orEmpty(),
                    folder = item.string("folder").orEmpty(),
                    tone = tone,
                    updatedAtSeconds = item.long("updatedAt"),
                )
            },
            publishedAtSeconds = root.long("publishedAt"),
        )
    } ?: AgentsSnapshot()

    private fun <T> parse(text: String?, read: (JsonObject) -> T): T? {
        if (text.isNullOrBlank()) return null
        return try {
            read(Json.parseToJsonElement(text).jsonObject)
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull

    private fun JsonObject.long(key: String): Long = (this[key] as? JsonPrimitive)?.longOrNull ?: 0

    private fun JsonObject.array(key: String): JsonArray = this[key] as? JsonArray ?: JsonArray(emptyList())
}

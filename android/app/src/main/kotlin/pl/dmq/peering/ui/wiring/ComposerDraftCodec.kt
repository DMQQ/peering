package pl.dmq.peering.ui.wiring

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import pl.dmq.peering.session.agent.ComposerDraft
import pl.dmq.peering.session.agent.ComposerDrafts

/**
 * The drafts as one JSON object keyed by session id. A store that cannot be read holds no drafts, so a damaged value
 * never stops the chats from opening.
 */
internal object ComposerDraftCodec {
    fun encode(drafts: ComposerDrafts): String = buildJsonObject {
        for ((sessionID, draft) in drafts.bySession) {
            put(
                sessionID,
                buildJsonObject {
                    put(TEXT, JsonPrimitive(draft.text))
                    put(
                        ATTACHED,
                        buildJsonArray { draft.attachedPaths.forEach { add(JsonPrimitive(it)) } },
                    )
                },
            )
        }
    }.toString()

    fun decode(text: String?): ComposerDrafts {
        if (text.isNullOrBlank()) return ComposerDrafts()
        val root = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return ComposerDrafts()
        val bySession = root.mapNotNull { (sessionID, value) -> draftOf(value)?.let { sessionID to it } }
        return ComposerDrafts(bySession.toMap())
    }

    private fun draftOf(value: JsonElement): ComposerDraft? {
        val entry = value as? JsonObject ?: return null
        val text = (entry[TEXT] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val paths = (entry[ATTACHED] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()
        return ComposerDraft(text = text, attachedPaths = paths)
    }

    private const val TEXT = "text"
    private const val ATTACHED = "attachedPaths"
}

package pl.dmq.peering.session.clipboard

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.wire.MAX_CLIPBOARD_IMAGE_BYTES
import java.util.concurrent.atomic.AtomicLong

/**
 * What the phone kept of the clipboards that moved, newest first. Text survives a relaunch when a [store] is given,
 * as on the iPhone; pictures stay in memory, bounded by [imageBudgetBytes] across the list. A repeat moves to the top.
 */
class ClipboardHistory(
    private val store: KeyValueStore? = null,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val limit: Int = DEFAULT_LIMIT,
    private val imageBudgetBytes: Int = DEFAULT_IMAGE_BUDGET_BYTES,
) {
    private val nextId = AtomicLong(1)
    private val mutable = MutableStateFlow(restore())
    val entries: StateFlow<List<ClipboardEntry>> = mutable.asStateFlow()

    fun record(content: ClipboardContent, direction: ClipboardDirection) {
        if (!remembers(content)) return
        val entry = ClipboardEntry(nextId.getAndIncrement(), content, nowMillis(), direction)
        mutable.update { current -> withinBudget((listOf(entry) + current.filterNot { it.content == content }).take(limit)) }
        persist()
    }

    fun remove(id: Long) {
        mutable.update { current -> current.filterNot { it.id == id } }
        persist()
    }

    fun clear() {
        mutable.value = emptyList()
        persist()
    }

    private fun remembers(content: ClipboardContent): Boolean = when (content) {
        is ClipboardContent.Text -> content.text.isNotBlank() && content.text.toByteArray().size <= MAX_TEXT_BYTES
        is ClipboardContent.Image -> content.png.isNotEmpty() && content.png.size <= MAX_CLIPBOARD_IMAGE_BYTES
    }

    /** Drops the oldest pictures until the rest fit; the newest entry is never the one dropped. */
    private fun withinBudget(entries: List<ClipboardEntry>): List<ClipboardEntry> {
        var total = entries.sumOf { (it.content as? ClipboardContent.Image)?.png?.size ?: 0 }
        val dropped = mutableSetOf<Long>()
        for (entry in entries.asReversed()) {
            if (total <= imageBudgetBytes || entry === entries.first()) break
            val image = entry.content as? ClipboardContent.Image ?: continue
            total -= image.png.size
            dropped += entry.id
        }
        return entries.filterNot { it.id in dropped }
    }

    private fun persist() {
        val texts = mutable.value.mapNotNull { entry ->
            (entry.content as? ClipboardContent.Text)?.let { Stored(it.text, entry.atMillis, entry.direction) }
        }
        store?.write(KEY, STORAGE.encodeToString(ListSerializer(Stored.serializer()), texts))
    }

    private fun restore(): List<ClipboardEntry> {
        val stored = store?.read(KEY) ?: return emptyList()
        val texts = try {
            STORAGE.decodeFromString(ListSerializer(Stored.serializer()), stored)
        } catch (error: IllegalArgumentException) {
            return emptyList()
        }
        return texts.take(limit).map { ClipboardEntry(nextId.getAndIncrement(), ClipboardContent.Text(it.text), it.at, it.direction) }
    }

    @Serializable
    private class Stored(val text: String, val at: Long, val direction: ClipboardDirection)

    companion object {
        const val DEFAULT_LIMIT = 25
        const val DEFAULT_IMAGE_BUDGET_BYTES = 32 * 1024 * 1024

        /** The iPhone keeps no text over this, since the stored list is decoded in full at every launch. */
        const val MAX_TEXT_BYTES = 100_000

        private const val KEY = "clipboard_history"
        private val STORAGE = Json { ignoreUnknownKeys = true }
    }
}

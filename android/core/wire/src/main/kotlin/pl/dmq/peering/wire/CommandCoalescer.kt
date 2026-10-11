package pl.dmq.peering.wire

enum class Coalescing {
    /** Sent exactly as offered and never merged, so a button event can neither be dropped nor reordered. */
    NONE,

    /** A newer item of the same kind replaces the one before it. */
    REPLACE_LATEST,

    /** A newer item of the same kind is merged into the one before it. */
    ACCUMULATE,
}

/**
 * Collapses queued commands. Only the last pending item can be merged into, so an item never moves past anything
 * queued after it. "Same kind" means the same runtime class. Not thread safe: the caller serialises [offer] and [drain].
 */
class CommandCoalescer<T : Any>(
    private val policy: (T) -> Coalescing,
    private val merge: (T, T) -> T,
) {
    private val pending = ArrayList<Pending<T>>()

    fun offer(item: T) {
        val coalescing = policy(item)
        val tail = pending.lastOrNull()
        if (tail != null && sameMergeableKind(tail, item, coalescing)) {
            tail.item = if (coalescing == Coalescing.ACCUMULATE) merge(tail.item, item) else item
        } else {
            pending.add(Pending(item, coalescing))
        }
    }

    private fun sameMergeableKind(tail: Pending<T>, item: T, coalescing: Coalescing): Boolean =
        coalescing != Coalescing.NONE && tail.coalescing == coalescing && tail.item::class == item::class

    /** Everything pending, in arrival order. The queue is empty afterwards. */
    fun drain(): List<T> {
        val items = pending.map { it.item }
        pending.clear()
        return items
    }

    private class Pending<T>(var item: T, val coalescing: Coalescing)
}

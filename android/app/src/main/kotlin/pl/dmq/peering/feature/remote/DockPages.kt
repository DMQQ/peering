package pl.dmq.peering.feature.remote

/** One button position in the dock: a control or a chord, and whether it is the first of its group. */
data class DockSlot(val groupId: String, val control: DockControl?, val action: QuickAction?, val startsGroup: Boolean)

/** The dock's slots laid onto pages of equal slot counts, and the page each group begins on. */
data class DockPages(val pages: List<List<DockSlot>>, val firstPageOfGroup: Map<String, Int>) {
    fun pageOfApplication(): Int? = firstPageOfGroup.entries.firstOrNull { it.key.startsWith(DockGroups.APP_PREFIX) }?.value
}

object DockPaging {
    const val MAX_PER_PAGE = 5
    const val MIN_PER_PAGE = 3

    /** Slots a page of [availableWidthDp] holds when each must be at least [slotMinDp] wide. */
    fun perPage(availableWidthDp: Float, slotMinDp: Float): Int =
        (availableWidthDp / slotMinDp).toInt().coerceIn(MIN_PER_PAGE, MAX_PER_PAGE)

    /** Fills pages in order, [perPage] to a page; a group that begins mid page simply continues where the last one stopped. */
    fun layout(groups: List<DockGroup>, perPage: Int): DockPages {
        val slots = groups.flatMap { group ->
            val all = group.controls.map { DockSlot(group.id, it, null, false) } + group.actions.map { DockSlot(group.id, null, it, false) }
            all.mapIndexed { index, slot -> if (index == 0) slot.copy(startsGroup = true) else slot }
        }
        val pages = slots.chunked(perPage.coerceAtLeast(1))
        val firstPage = LinkedHashMap<String, Int>()
        pages.forEachIndexed { index, page -> page.filter { it.startsGroup }.forEach { firstPage.putIfAbsent(it.groupId, index) } }
        return DockPages(pages, firstPage)
    }
}

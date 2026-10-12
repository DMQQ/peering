package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FileSortTest {
    private val entries = listOf(
        file("zeta.txt", size = 10, modified = 100.0),
        folder("beta", modified = 50.0),
        file("Alpha.txt", size = 500, modified = 300.0),
        folder("Gamma", modified = 200.0),
    )

    @Test
    fun nameOrderPutsFoldersFirstAndIgnoresCase() {
        assertEquals(listOf("beta", "Gamma", "Alpha.txt", "zeta.txt"), FileSort.NAME.sorted(entries).map { it.name })
    }

    @Test
    fun sizeOrderIsLargestFirstWithinEachGroup() {
        assertEquals(listOf("beta", "Gamma", "Alpha.txt", "zeta.txt"), FileSort.SIZE.sorted(entries).map { it.name })
        val files = FileSort.SIZE.sorted(entries).filterNot { it.isDirectory }.map { it.name }
        assertEquals(listOf("Alpha.txt", "zeta.txt"), files)
    }

    @Test
    fun modifiedOrderIsNewestFirstAndAnUndatedEntryIsLast() {
        val undated = file("undated")
        val sorted = FileSort.MODIFIED.sorted(entries + undated).filterNot { it.isDirectory }.map { it.name }
        assertEquals(listOf("Alpha.txt", "zeta.txt", "undated"), sorted)
    }

    @Test
    fun foldersStayAboveFilesInEveryOrder() {
        FileSort.entries.forEach { order ->
            val sorted = order.sorted(entries)
            assertTrue(sorted.take(2).all { it.isDirectory })
        }
    }
}

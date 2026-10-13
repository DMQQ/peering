package pl.dmq.peering.imaging

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedFilesTest {
    private val directory: File = Files.createTempDirectory("shared").toFile()
    private val day = 24L * 60 * 60 * 1000

    @Test
    fun nameIsTheSha256OfTheContent() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.png",
            SharedFiles.nameFor("abc".toByteArray(), "png"),
        )
    }

    @Test
    fun differentContentGetsADifferentName() {
        assertNotEquals(SharedFiles.nameFor(byteArrayOf(1), "png"), SharedFiles.nameFor(byteArrayOf(2), "png"))
    }

    @Test
    fun equalContentReusesTheFile() {
        val first = SharedFiles.write(directory, byteArrayOf(1, 2), "png", now = 1_000)
        val second = SharedFiles.write(directory, byteArrayOf(1, 2), "png", now = 2_000)

        assertEquals(first, second)
        assertEquals(1, directory.listFiles()!!.size)
    }

    @Test
    fun aWriteLeavesOnlyTheContentNamedFile() {
        val file = SharedFiles.write(directory, byteArrayOf(1, 2, 3), "png", now = 1_000)

        assertEquals(listOf(file.name), directory.list()!!.toList())
        assertEquals(listOf<Byte>(1, 2, 3), file.readBytes().toList())
    }

    @Test
    fun aTruncatedFileOfTheSameNameIsReplacedWhole() {
        val bytes = byteArrayOf(1, 2, 3)
        File(directory, SharedFiles.nameFor(bytes, "png")).writeBytes(byteArrayOf(1))

        val file = SharedFiles.write(directory, bytes, "png", now = 1_000)

        assertEquals(bytes.toList(), file.readBytes().toList())
        assertEquals(1, directory.listFiles()!!.size)
    }

    @Test
    fun filesOlderThanADayArePruned() {
        val old = File(directory, "old.png").apply { writeBytes(byteArrayOf(1)); setLastModified(1_000) }

        SharedFiles.write(directory, byteArrayOf(9), "png", now = 1_000 + day + 1)

        assertFalse(old.exists())
    }

    @Test
    fun recentFilesSurvive() {
        val recent = File(directory, "recent.png").apply { writeBytes(byteArrayOf(1)); setLastModified(5_000) }

        SharedFiles.write(directory, byteArrayOf(9), "png", now = 6_000)

        assertTrue(recent.exists())
    }

    @Test
    fun oldestFilesGoFirstWhenTheFolderIsOverBudget() {
        val older = File(directory, "a.bin").apply { writeBytes(ByteArray(40 * 1024 * 1024)); setLastModified(1_000) }
        val newer = File(directory, "b.bin").apply { writeBytes(ByteArray(40 * 1024 * 1024)); setLastModified(2_000) }

        SharedFiles.prune(directory, now = 3_000)

        assertFalse(older.exists())
        assertTrue(newer.exists())
    }
}

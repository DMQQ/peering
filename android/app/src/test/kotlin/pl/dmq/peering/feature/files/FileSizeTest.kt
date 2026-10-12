package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.files.FileSize.SizeUnit

class FileSizeTest {
    @Test
    fun smallCountsStayInBytes() {
        assertEquals(FileSize(1023.0, SizeUnit.BYTES), FileSize.of(1023))
    }

    @Test
    fun kilobytesMegabytesAndGigabytesScaleByPowersOfTwo() {
        assertEquals(FileSize(1.0, SizeUnit.KILOBYTES), FileSize.of(1024))
        assertEquals(FileSize(2.0, SizeUnit.MEGABYTES), FileSize.of(2L * 1024 * 1024))
        assertEquals(FileSize(3.0, SizeUnit.GIGABYTES), FileSize.of(3L * 1024 * 1024 * 1024))
    }

    @Test
    fun aNegativeCountIsShownAsZero() {
        assertEquals(FileSize(0.0, SizeUnit.BYTES), FileSize.of(-5))
    }
}

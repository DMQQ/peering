package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.files.FileSize.SizeUnit

class FileSizeTest {
    @Test
    fun smallCountsStayInBytes() {
        assertEquals(FileSize(999.0, SizeUnit.BYTES), FileSize.of(999))
    }

    @Test
    fun unitsScaleByPowersOfTen() {
        assertEquals(FileSize(1.0, SizeUnit.KILOBYTES), FileSize.of(1000))
        assertEquals(FileSize(2.0, SizeUnit.MEGABYTES), FileSize.of(2_000_000))
        assertEquals(FileSize(3.0, SizeUnit.GIGABYTES), FileSize.of(3_000_000_000))
    }

    @Test
    fun aNegativeCountIsShownAsZero() {
        assertEquals(FileSize(0.0, SizeUnit.BYTES), FileSize.of(-5))
    }

    @Test
    fun theEmptyFileIsNamedNotCounted() {
        assertEquals("Zero bytes", fileSizeLabel(0))
        assertEquals("1 byte", fileSizeLabel(1))
        assertEquals("704 bytes", fileSizeLabel(704))
    }

    @Test
    fun kilobytesAreWholeAndLargerUnitsKeepOneOrTwoDecimals() {
        assertEquals("12 KB", fileSizeLabel(12_345))
        assertEquals("1.2 MB", fileSizeLabel(1_234_567))
        assertEquals("1.07 GB", fileSizeLabel(1_070_000_000))
    }

    @Test
    fun aRoundFigureDropsItsDecimals() {
        assertEquals("2 MB", fileSizeLabel(2_000_000))
        assertEquals("3 GB", fileSizeLabel(3_000_000_000))
    }
}

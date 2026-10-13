package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test

class PathLabelTest {
    @Test
    fun aShortPathIsUntouched() {
        assertEquals("/Users/dmq", headTruncated("/Users/dmq"))
    }

    @Test
    fun aLongPathLosesItsFrontAtAFolderBoundary() {
        assertEquals("…/projects/Peering", headTruncated("/Users/dmq/Desktop/projects/Peering", limit = 20))
    }

    @Test
    fun aSingleLongNameIsCutMidName() {
        assertEquals("…cdefghij", headTruncated("abcdefghij", limit = 9))
    }
}

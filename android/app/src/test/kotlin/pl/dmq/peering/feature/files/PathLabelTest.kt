package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test

class PathLabelTest {
    @Test
    fun aShortPathIsUntouched() {
        assertEquals("/Users/alex", headTruncated("/Users/alex"))
    }

    @Test
    fun aLongPathLosesItsFrontAtAFolderBoundary() {
        assertEquals("…/projects/Peering", headTruncated("/Users/alex/Desktop/projects/Peering", limit = 20))
    }

    @Test
    fun aSingleLongNameIsCutMidName() {
        assertEquals("…cdefghij", headTruncated("abcdefghij", limit = 9))
    }
}

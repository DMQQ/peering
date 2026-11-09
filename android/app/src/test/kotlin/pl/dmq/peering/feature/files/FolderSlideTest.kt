package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderSlideTest {
    @Test
    fun goingDeeperStartsOnTheRight() {
        assertEquals(400f, FolderSlide.startOffset("/Users/me", "/Users/me/Projects", 400f), 0f)
    }

    @Test
    fun goingBackStartsOnTheLeft() {
        assertEquals(-400f, FolderSlide.startOffset("/Users/me/Projects", "/Users/me", 400f), 0f)
    }

    @Test
    fun aSiblingFolderCountsAsDeeper() {
        assertEquals(400f, FolderSlide.startOffset("/Users/me/a", "/Users/me/b", 400f), 0f)
    }

    @Test
    fun theFirstListingComesInFromTheRight() {
        assertEquals(400f, FolderSlide.startOffset(null, "/Users/me", 400f), 0f)
    }

    @Test
    fun theRootHasNoDepthAndTrailingSlashesDoNotCount() {
        assertEquals(0, FolderSlide.depth("/"))
        assertEquals(2, FolderSlide.depth("/Users/me/"))
    }
}

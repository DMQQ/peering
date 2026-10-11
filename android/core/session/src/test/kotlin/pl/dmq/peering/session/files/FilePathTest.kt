package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FilePathTest {
    @Test
    fun parentOfAPosixFolderStepsUpOneSegment() {
        assertEquals("/Users", FilePath.parent("/Users/me"))
        assertEquals("/", FilePath.parent("/Users"))
    }

    @Test
    fun theRootHasNoParent() {
        assertNull(FilePath.parent("/"))
        assertTrue(FilePath.isRoot("/"))
    }

    @Test
    fun parentOfAWindowsFolderStepsUpToItsDriveRoot() {
        assertEquals("/C:/Users", FilePath.parent("/C:/Users/me"))
        assertEquals("/C:/", FilePath.parent("/C:/Users"))
        assertNull(FilePath.parent("/C:/"))
        assertTrue(FilePath.isRoot("/C:/"))
        assertTrue(FilePath.isRoot("/C:"))
    }

    @Test
    fun childJoinsWithoutDoublingTheSlash() {
        assertEquals("/Users/me", FilePath.child("/Users", "me"))
        assertEquals("/Users/me", FilePath.child("/Users/", "me"))
        assertEquals("/home", FilePath.child("/", "home"))
        assertEquals("/C:/Users", FilePath.child("/C:/", "Users"))
    }

    @Test
    fun breadcrumbsStartAtTheRootAndEndAtThePath() {
        assertEquals(
            listOf(
                FilePath.Breadcrumb("/", "/"),
                FilePath.Breadcrumb("Users", "/Users"),
                FilePath.Breadcrumb("me", "/Users/me"),
            ),
            FilePath.breadcrumbs("/Users/me"),
        )
    }

    @Test
    fun breadcrumbsOfAWindowsPathStartWithTheDrive() {
        assertEquals(
            listOf(
                FilePath.Breadcrumb("C:", "/C:/"),
                FilePath.Breadcrumb("Users", "/C:/Users"),
                FilePath.Breadcrumb("me", "/C:/Users/me"),
            ),
            FilePath.breadcrumbs("/C:/Users/me"),
        )
    }

    @Test
    fun aTrailingSlashDoesNotAddACrumb() {
        assertEquals(FilePath.breadcrumbs("/Users/me"), FilePath.breadcrumbs("/Users/me/"))
    }

    @Test
    fun nameIsTheLastSegmentOrTheRootTitle() {
        assertEquals("me", FilePath.name("/Users/me"))
        assertEquals("/", FilePath.name("/"))
        assertEquals("C:", FilePath.name("/C:/"))
    }
}

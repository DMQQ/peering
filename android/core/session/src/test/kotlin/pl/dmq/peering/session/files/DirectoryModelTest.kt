package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.RemoteDirectoryEntry

class DirectoryModelTest {
    private fun entry(name: String, isDirectory: Boolean, permissions: String = "-rw-r--r--") = RemoteDirectoryEntry(
        name = name,
        isDirectory = isDirectory,
        isSymlink = false,
        size = 0,
        permissions = permissions,
        modified = null,
    )

    @Test
    fun foldersComeFirstThenNamesIgnoringCase() {
        val model = DirectoryModel(
            path = "/Users/me",
            entries = listOf(
                entry("zeta.txt", isDirectory = false),
                entry("Projects", isDirectory = true),
                entry("alpha.txt", isDirectory = false),
                entry("apps", isDirectory = true),
            ),
            isTruncated = false,
        )
        assertEquals(
            listOf("apps", "Projects", "alpha.txt", "zeta.txt"),
            model.visibleEntries.map { it.name },
        )
    }

    @Test
    fun dotfilesAreHiddenUnlessAskedFor() {
        val entries = listOf(entry(".ssh", isDirectory = true), entry("notes", isDirectory = false))
        assertEquals(listOf("notes"), DirectoryModel("/", entries, isTruncated = false).visibleEntries.map { it.name })
        assertEquals(
            listOf(".ssh", "notes"),
            DirectoryModel("/", entries, isTruncated = false, showHidden = true).visibleEntries.map { it.name },
        )
    }

    @Test
    fun executableBitComesFromThePermissionsString() {
        val model = DirectoryModel(
            path = "/bin",
            entries = listOf(
                entry("run", isDirectory = false, permissions = "-rwxr-xr-x"),
                entry("data", isDirectory = false, permissions = "-rw-r--r--"),
            ),
            isTruncated = false,
        )
        assertEquals(listOf(false, true), model.visibleEntries.map { it.isExecutable })
    }

    @Test
    fun aWindowsListingExposesItsBreadcrumbsAndParent() {
        val model = DirectoryModel("/C:/Users/me", emptyList(), isTruncated = true)
        assertEquals(listOf("C:", "Users", "me"), model.breadcrumbs.map { it.title })
        assertEquals("/C:/Users", model.parentPath)
        assertEquals(true, model.isTruncated)
    }

    @Test
    fun theRootListingHasNoParent() {
        assertNull(DirectoryModel("/", emptyList(), isTruncated = false).parentPath)
    }
}

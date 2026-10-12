package pl.dmq.peering.feature.remote

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PixelSize

class SourceGroupingTest {
    private fun application(pid: Int, title: String, bundle: String?) = CaptureSourceDescriptor(
        id = "application:$pid",
        kind = CaptureSourceKind.APPLICATION,
        title = title,
        bundleIdentifier = bundle,
        source = CaptureSource.Application(pid),
        pixelSize = PixelSize(1.0, 1.0),
    )

    private fun window(id: Long, title: String, owner: String?, bundle: String?) = CaptureSourceDescriptor(
        id = "window:$id",
        kind = CaptureSourceKind.WINDOW,
        title = title,
        subtitle = owner,
        bundleIdentifier = bundle,
        source = CaptureSource.Window(id),
        pixelSize = PixelSize(800.0, 600.0),
    )

    @Test
    fun windowsJoinTheApplicationWithTheSameBundleInTheCataloguesOrder() {
        val safari = application(1, "Safari", "com.apple.Safari")
        val groups = SourceGrouping.applicationGroups(
            listOf(safari),
            listOf(
                window(1, "Inbox", "Mail", "com.apple.mail"),
                window(2, "Docs", "Safari", "com.apple.Safari"),
                window(3, "News", "Safari", "com.apple.Safari"),
            ),
        )

        assertEquals(listOf("group:b:com.apple.mail", "application:1"), groups.map { it.id })
        assertEquals(listOf("Docs", "News"), groups[1].windows.map { it.title })
        assertEquals(safari, groups[1].application)
        assertNull(groups[0].application)
        assertEquals("Mail", groups[0].title)
    }

    @Test
    fun aWindowWithNoBundleGroupsByItsOwnersName() {
        val groups = SourceGrouping.applicationGroups(emptyList(), listOf(window(1, "a", "Tool", null), window(2, "b", "tool", null)))

        assertEquals(1, groups.size)
        assertEquals(2, groups.single().windows.size)
    }

    @Test
    fun aHeadingMatchKeepsEveryWindowAndAWindowMatchKeepsOnlyItself() {
        val groups = SourceGrouping.applicationGroups(
            listOf(application(1, "Safari", "com.apple.Safari")),
            listOf(window(1, "Docs", "Safari", "com.apple.Safari"), window(2, "News", "Safari", "com.apple.Safari")),
        )

        assertEquals(2, SourceGrouping.filtered(groups, "safari").single().windows.size)
        assertEquals(listOf("News"), SourceGrouping.filtered(groups, "news").single().windows.map { it.title })
        assertEquals(emptyList<ApplicationGroup>(), SourceGrouping.filtered(groups, "zzz"))
    }

    @Test
    fun installedApplicationsLeaveOutTheOnesAlreadyRunning() {
        val catalog = CaptureCatalog(
            applications = listOf(application(1, "Safari", "com.apple.Safari")),
            installedApplications = listOf(
                buildJsonObject {
                    put("bundleIdentifier", "com.apple.Safari")
                    put("title", "Safari")
                },
                buildJsonObject {
                    put("bundleIdentifier", "com.apple.Notes")
                    put("title", "Notes")
                },
            ),
        )

        assertEquals(listOf("Notes"), SourceGrouping.installedNotRunning(catalog, "").map { it.title })
        assertEquals(emptyList<InstalledApplication>(), SourceGrouping.installedNotRunning(catalog, "zzz"))
    }
}

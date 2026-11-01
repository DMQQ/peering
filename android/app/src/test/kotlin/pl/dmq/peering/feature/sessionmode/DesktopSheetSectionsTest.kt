package pl.dmq.peering.feature.sessionmode

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PixelSize

class DesktopSheetSectionsTest {
    private fun display(id: Long, title: String) = CaptureSourceDescriptor(
        id = "display:$id",
        kind = CaptureSourceKind.DISPLAY,
        title = title,
        source = CaptureSource.Display(id),
        pixelSize = PixelSize(1600.0, 1000.0),
    )

    private fun catalog(spaces: String, vararg displays: CaptureSourceDescriptor) =
        CaptureCatalog(displays = displays.toList(), spaceInfo = Json.parseToJsonElement(spaces))

    @Test
    fun oneDisplayListsItsDesktopsWithoutALabel() {
        val sections = DesktopSheetSections.of(catalog("""{"displays":[{"displayID":1,"count":3,"current":2}]}""", display(1, "Built-in")))
        assertEquals(listOf(null), sections.map { it.title })
        assertEquals(3, sections.single().display.count)
    }

    @Test
    fun severalDisplaysEachGetTheirNameAsALabel() {
        val sections = DesktopSheetSections.of(
            catalog("""{"displays":[{"displayID":1,"count":2},{"displayID":2,"count":1}]}""", display(1, "Built-in"), display(2, "Studio")),
        )
        assertEquals(listOf("Built-in", "Studio"), sections.map { it.title })
    }

    @Test
    fun noCatalogueHasNoDesktops() {
        assertEquals(emptyList<DesktopSheetSection>(), DesktopSheetSections.of(null))
    }
}

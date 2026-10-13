package pl.dmq.peering.session.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import kotlinx.serialization.json.JsonObject
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource

class SourceSelectionTest {
    private val main = display(id = 1, width = 2880.0, height = 1800.0)
    private val external = display(id = 2, width = 1920.0, height = 1080.0)
    private val sameSizeAsMain = display(id = 3, width = 2880.0, height = 1800.0)
    private val catalog = CaptureCatalog(displays = listOf(main, external, sameSizeAsMain))

    @Test
    fun chooseReturnsTheSwitchAndRemembersTheSourceForTheNextHello() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)

        val command = selection.choose(external.source)

        assertEquals(SetCaptureSource(external.source), command)
        assertEquals(external.source, selection.chosen)
        assertEquals(external.source.toJson(), selection.resumeSourceJson())
    }

    @Test
    fun aSwitchToAnotherPixelSizeOwesOneConfig() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)
        selection.choose(main.source)

        selection.choose(external.source)

        assertEquals(1, selection.configUpdatesOwed)
        selection.onVideoConfig()
        assertEquals(0, selection.configUpdatesOwed)
    }

    @Test
    fun aSwitchToTheSameSizeOwesNoConfig() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)
        selection.choose(main.source)

        selection.choose(sameSizeAsMain.source)

        assertEquals(0, selection.configUpdatesOwed)
    }

    @Test
    fun aSourceTheCatalogueDoesNotDescribeOwesNoConfig() {
        val selection = SourceSelection()
        selection.choose(main.source)

        selection.choose(external.source)

        assertEquals(0, selection.configUpdatesOwed)
    }

    @Test
    fun extraConfigsWithNothingOwedDoNotGoNegative() {
        val selection = SourceSelection()

        selection.onVideoConfig()

        assertEquals(0, selection.configUpdatesOwed)
    }

    @Test
    fun aVanishedSourceFallsBackToTheFirstDisplay() {
        val selection = SourceSelection(restored = CaptureSource.Window(99))

        val command = selection.onCatalog(catalog)

        assertEquals(SetCaptureSource(main.source), command)
        assertEquals(main.source, selection.chosen)
        assertEquals(main.source, selection.resumeSource)
    }

    @Test
    fun aSourceTheCatalogueStillOffersIsKeptWithoutACommand() {
        val selection = SourceSelection(restored = external.source)

        assertNull(selection.onCatalog(catalog))
        assertEquals(external.source, selection.chosen)
    }

    @Test
    fun aMosaicIsNeverTreatedAsGone() {
        val mosaic = CaptureSource.Mosaic(JsonObject(emptyMap()))
        val selection = SourceSelection(restored = mosaic)

        assertNull(selection.onCatalog(catalog))
        assertEquals(mosaic, selection.chosen)
    }

    @Test
    fun aCatalogueWithoutDisplaysClearsTheVanishedSource() {
        val selection = SourceSelection(restored = CaptureSource.Window(99))

        assertNull(selection.onCatalog(CaptureCatalog()))
        assertNull(selection.chosen)
        assertNull(selection.resumeSourceJson())
    }

    @Test
    fun inputTransformFitsTheActiveSourceAndMapsTapsIntoIt() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)
        selection.choose(main.source)

        val transform = selection.inputTransform(viewWidth = 400.0, viewHeight = 800.0)!!

        assertEquals(0.0, transform.originX, 1e-9)
        assertEquals(275.0, transform.originY, 1e-9)
        assertEquals(0.5, transform.normalizedPoint(200.0, 400.0).x, 1e-9)
        assertEquals(0.5, transform.normalizedPoint(200.0, 400.0).y, 1e-9)
        assertEquals(0.0, transform.normalizedPoint(0.0, 0.0).x, 1e-9)
        assertEquals(0.0, transform.normalizedPoint(0.0, 0.0).y, 1e-9)
        assertEquals(1.0, transform.normalizedPoint(900.0, 900.0).x, 1e-9)
        assertEquals(1.0, transform.normalizedPoint(900.0, 900.0).y, 1e-9)
    }

    @Test
    fun inputTransformIsAbsentWithoutADescribedSource() {
        val selection = SourceSelection()
        selection.onCatalog(catalog)

        assertNull(selection.inputTransform(viewWidth = 400.0, viewHeight = 800.0))
    }

    private fun display(id: Long, width: Double, height: Double) = CaptureSourceDescriptor(
        id = "display:$id",
        kind = CaptureSourceKind.DISPLAY,
        title = "Display $id",
        source = CaptureSource.Display(id),
        pixelSize = PixelSize(width, height),
    )
}

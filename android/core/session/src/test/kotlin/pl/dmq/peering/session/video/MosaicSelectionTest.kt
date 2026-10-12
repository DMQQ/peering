package pl.dmq.peering.session.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.MosaicTile
import pl.dmq.peering.wire.NormalizedRect
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource

class MosaicSelectionTest {
    private val layout = MosaicLayout(
        PixelSize(1280.0, 720.0),
        listOf(
            MosaicTile(CaptureSource.Window(1), NormalizedRect(0.0, 0.0, 0.5, 1.0)),
            MosaicTile(CaptureSource.Window(2), NormalizedRect(0.5, 0.0, 0.5, 1.0)),
        ),
        15,
    )

    @Test
    fun choosingAMosaicSendsItThroughTheSameCommandAsAnySource() {
        val selection = SourceSelection()

        val command = selection.choose(CaptureSource.Mosaic(layout))

        assertEquals(SetCaptureSource(CaptureSource.Mosaic(layout)), command)
        assertEquals(layout, selection.rememberedMosaic)
    }

    @Test
    fun theMosaicIsRememberedAcrossAVisitToOneOfItsTiles() {
        val selection = SourceSelection()
        selection.choose(CaptureSource.Mosaic(layout))

        selection.choose(CaptureSource.Window(2))

        assertEquals(CaptureSource.Window(2), selection.chosen)
        assertEquals(layout, selection.rememberedMosaic)
    }

    @Test
    fun aSessionThatNeverShowedAMosaicHasNothingToReturnTo() {
        assertNull(SourceSelection().rememberedMosaic)
    }

    @Test
    fun aMosaicIsNeverTreatedAsGoneWhenTheCatalogueArrives() {
        val selection = SourceSelection()
        selection.choose(CaptureSource.Mosaic(layout))

        assertNull(selection.onCatalog(CaptureCatalog()))
        assertEquals(CaptureSource.Mosaic(layout), selection.chosen)
    }
}

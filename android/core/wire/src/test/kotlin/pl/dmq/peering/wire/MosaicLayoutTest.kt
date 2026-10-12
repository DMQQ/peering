package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MosaicLayoutTest {
    private val left = MosaicTile(CaptureSource.Window(7), NormalizedRect(0.0, 0.0, 0.5, 1.0))
    private val right = MosaicTile(CaptureSource.Display(2), NormalizedRect(0.5, 0.0, 0.5, 1.0))
    private val layout = MosaicLayout(PixelSize(1280.0, 720.0), listOf(left, right), 15)

    @Test
    fun theSelectionCommandCarriesTheSwiftShapeOfALayout() {
        val text = SetCaptureSource(CaptureSource.Mosaic(layout)).toJson()

        assertTrue(text.contains(""""canvas":[1280.0,720.0]"""))
        assertTrue(text.contains(""""source":{"window":{"_0":7}}"""))
        assertTrue(text.contains(""""rect":{"x":0.5,"y":0.0,"width":0.5,"height":1.0}"""))
        assertTrue(text.contains(""""frameRate":15"""))
    }

    @Test
    fun aMosaicSourceRoundTripsThroughTheCommand() {
        val command = SetCaptureSource(CaptureSource.Mosaic(layout))

        val parsed = RemoteCommand.parse(command.toJson()) as SetCaptureSource

        assertEquals(layout, (parsed.source as CaptureSource.Mosaic).layout)
    }

    @Test
    fun aPayloadThatIsNotALayoutReadsAsNone() {
        assertNull(CaptureSource.Mosaic(JsonPrimitive("x")).layout)
    }

    @Test
    fun theSharedEdgeBelongsToTheTileOnItsFarSide() {
        assertEquals(0, layout.tileIndexAt(NormalizedPoint(0.49, 0.5)))
        assertEquals(1, layout.tileIndexAt(NormalizedPoint(0.5, 0.5)))
    }

    @Test
    fun aPointNoTileHoldsIsNone() {
        val sparse = layout.copy(tiles = listOf(left))

        assertNull(sparse.tileIndexAt(NormalizedPoint(0.9, 0.5)))
    }

    @Test
    fun aMosaicBlocksPointsAndKeysButNotSpaceSwitching() {
        assertTrue(MouseDown(MouseButton.LEFT).isBlockedByMosaic)
        assertTrue(KeyDown(36, Modifiers(0)).isBlockedByMosaic)
        assertTrue(JoystickMove(1.0, 1.0).isBlockedByMosaic)
        assertFalse(SwitchSpace(SpaceDirection.LEFT).isBlockedByMosaic)
        assertFalse(SetCaptureSource(CaptureSource.Display(1)).isBlockedByMosaic)
    }
}

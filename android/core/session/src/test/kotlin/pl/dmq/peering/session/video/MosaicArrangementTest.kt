package pl.dmq.peering.session.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PixelSize

class MosaicArrangementTest {
    private val a = CaptureSource.Window(1)
    private val b = CaptureSource.Window(2)
    private val c = CaptureSource.Window(3)
    private val arrangement = MosaicArrangement.of(listOf(a, b, c))

    @Test
    fun `moving a tile later shifts the ones it passes forward`() {
        assertEquals(listOf(b, c, a), arrangement.moved(0, 2).sources)
    }

    @Test
    fun `moving a tile earlier shifts the ones it passes back`() {
        assertEquals(listOf(c, a, b), arrangement.moved(2, 0).sources)
    }

    @Test
    fun `a move outside the tiles or onto itself changes nothing`() {
        assertSame(arrangement, arrangement.moved(1, 1))
        assertSame(arrangement, arrangement.moved(-1, 1))
        assertSame(arrangement, arrangement.moved(0, 3))
    }

    @Test
    fun `removing a tile keeps the order and a tile that is not there is ignored`() {
        assertEquals(listOf(a, c), arrangement.removed(1).sources)
        assertSame(arrangement, arrangement.removed(5))
    }

    @Test
    fun `removing down to one tile is no longer a mosaic`() {
        assertFalse(arrangement.removed(0).removed(0).isMosaic)
    }

    @Test
    fun `resizing steps the weight and stops at both ends`() {
        val grown = arrangement.resized(0, 1).resized(0, 1)
        assertEquals(3, grown.choices[0].weight)
        assertSame(grown, grown.resized(0, 1))
        assertSame(arrangement, arrangement.resized(0, -1))
    }

    @Test
    fun `weights survive a reorder with their tile`() {
        val moved = arrangement.resized(0, 1).moved(0, 2)
        assertEquals(2, moved.choices[2].weight)
        assertEquals(a, moved.choices[2].source)
    }

    @Test
    fun `a heavier tile takes a larger share of its row`() {
        val rects = MosaicGrid.rects(listOf(2, 1, 1, 1), portrait = false)

        assertEquals(2.0 / 3.0, rects[0].width, 1e-9)
        assertEquals(1.0 / 3.0, rects[1].width, 1e-9)
        assertEquals(2.0 / 3.0, rects[1].x, 1e-9)
        assertEquals(0.5, rects[2].width, 1e-9)
    }

    @Test
    fun `equal weights match the plain grid`() {
        assertEquals(MosaicGrid.rects(4, portrait = true), MosaicGrid.rects(listOf(1, 1, 1, 1), portrait = true))
    }

    @Test
    fun `a short last row keeps its tile the size of the others`() {
        val rects = MosaicGrid.rects(listOf(1, 1, 3), portrait = false)

        assertEquals(0.5, rects[2].width, 1e-9)
        assertEquals(0.5, rects[2].y, 1e-9)
    }

    @Test
    fun `the layout carries the weights and refuses a single tile`() {
        val phone = PixelSize(2400.0, 1080.0)
        val layout = MosaicGrid.layout(arrangement.resized(0, 2).removed(2), phone, null)
        assertNotNull(layout)
        assertEquals(0.75, layout!!.tiles[0].rect.width, 1e-9)
        assertNull(MosaicGrid.layout(arrangement.removed(0).removed(0), phone, null))
    }
}

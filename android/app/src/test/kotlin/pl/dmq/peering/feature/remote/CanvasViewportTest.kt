package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class CanvasViewportTest {
    private val canvas = CanvasSize(1000.0, 1000.0)
    private val fullCanvas = CanvasRect(0.0, 0.0, 1000.0, 1000.0)

    @Test
    fun `zoom never goes below fitted`() {
        val viewport = CanvasViewport().zoomedAbout(0.5, 500.0, 500.0, canvas)

        assertEquals(CanvasViewport.MIN_ZOOM, viewport.zoom, EPSILON)
        assertEquals(0.0, viewport.panX, EPSILON)
        assertEquals(0.0, viewport.panY, EPSILON)
    }

    @Test
    fun `zoom stops at the maximum`() {
        val viewport = CanvasViewport().zoomedAbout(10.0, 500.0, 500.0, canvas)

        assertEquals(CanvasViewport.MAX_ZOOM, viewport.zoom, EPSILON)
    }

    @Test
    fun `zooming keeps the point under the fingers where it was`() {
        val viewport = CanvasViewport().zoomedAbout(2.0, 300.0, 200.0, canvas)

        assertEquals(2.0, viewport.zoom, EPSILON)
        assertEquals(-300.0, viewport.panX, EPSILON)
        assertEquals(-200.0, viewport.panY, EPSILON)
        val point = viewport.canvasToPicture(300.0, 200.0, fullCanvas)
        assertEquals(0.3, point.x, EPSILON)
        assertEquals(0.2, point.y, EPSILON)
    }

    @Test
    fun `pan cannot leave an uncovered edge`() {
        val zoomed = CanvasViewport(zoom = 2.0)

        assertEquals(0.0, zoomed.pannedBy(500.0, 500.0, canvas).panX, EPSILON)
        assertEquals(-1000.0, zoomed.pannedBy(-5000.0, -5000.0, canvas).panX, EPSILON)
        assertEquals(-1000.0, zoomed.pannedBy(-5000.0, -5000.0, canvas).panY, EPSILON)
    }

    @Test
    fun `a fitted picture is drawn where the viewport puts it`() {
        val displayed = CanvasViewport(zoom = 2.0, panX = -100.0, panY = 0.0).displayed(fullCanvas)

        assertEquals(-100.0, displayed.left, EPSILON)
        assertEquals(0.0, displayed.top, EPSILON)
        assertEquals(2000.0, displayed.width, EPSILON)
        assertEquals(2000.0, displayed.height, EPSILON)
    }

    @Test
    fun `an unzoomed viewport maps canvas points straight onto the picture`() {
        val fit = CanvasRect(left = 0.0, top = 218.75, width = 1000.0, height = 562.5)

        val point = CanvasViewport().canvasToPicture(500.0, 500.0, fit)

        assertEquals(0.5, point.x, EPSILON)
        assertEquals(0.5, point.y, EPSILON)
    }

    private companion object {
        const val EPSILON = 1e-6
    }
}

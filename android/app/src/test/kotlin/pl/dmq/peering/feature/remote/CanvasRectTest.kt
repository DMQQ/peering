package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.PixelSize

class CanvasRectTest {
    @Test
    fun `a wide picture is letterboxed top and bottom in a square canvas`() {
        val fit = aspectFitRect(PixelSize(1920.0, 1080.0), CanvasSize(1000.0, 1000.0))!!

        assertEquals(0.0, fit.left, EPSILON)
        assertEquals(218.75, fit.top, EPSILON)
        assertEquals(1000.0, fit.width, EPSILON)
        assertEquals(562.5, fit.height, EPSILON)
    }

    @Test
    fun `a tall picture is pillarboxed left and right in a wide canvas`() {
        val fit = aspectFitRect(PixelSize(1000.0, 2000.0), CanvasSize(1000.0, 500.0))!!

        assertEquals(375.0, fit.left, EPSILON)
        assertEquals(0.0, fit.top, EPSILON)
        assertEquals(250.0, fit.width, EPSILON)
        assertEquals(500.0, fit.height, EPSILON)
    }

    @Test
    fun `an empty picture or canvas fits nothing`() {
        assertNull(aspectFitRect(PixelSize(0.0, 1080.0), CanvasSize(1000.0, 1000.0)))
        assertNull(aspectFitRect(PixelSize(1920.0, 1080.0), CanvasSize(1000.0, 0.0)))
    }

    @Test
    fun `a point inside the picture maps to its fraction and an outside point clamps to the edge`() {
        val fit = CanvasRect(left = 100.0, top = 50.0, width = 200.0, height = 100.0)

        val inside = fit.normalize(200.0, 100.0)
        assertEquals(0.5, inside.x, EPSILON)
        assertEquals(0.5, inside.y, EPSILON)

        val outside = fit.normalize(10.0, 400.0)
        assertEquals(0.0, outside.x, EPSILON)
        assertEquals(1.0, outside.y, EPSILON)
    }

    private companion object {
        const val EPSILON = 1e-6
    }
}

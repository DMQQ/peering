package pl.dmq.peering.ui.theme

import androidx.compose.ui.graphics.Color
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Test

class PeeringColorsTest {
    private fun Color.rgb(): Triple<Int, Int, Int> =
        Triple((red * 255).roundToInt(), (green * 255).roundToInt(), (blue * 255).roundToInt())

    private fun assertOpaque(expected: Triple<Int, Int, Int>, color: Color) {
        assertEquals(expected, color.rgb())
        assertEquals(1f, color.alpha, 0.001f)
    }

    @Test
    fun solidTokensMatchDesignHexValues() {
        assertOpaque(Triple(0x0A, 0x0A, 0x0B), PeeringColors.backdrop)
        assertOpaque(Triple(0xFF, 0xFF, 0xFF), PeeringColors.ink)
        assertOpaque(Triple(0x00, 0x00, 0x00), PeeringColors.onInk)
        assertOpaque(Triple(0x0A, 0x84, 0xFF), PeeringColors.accent)
        assertOpaque(Triple(0xFA, 0x73, 0x66), PeeringColors.danger)
        assertOpaque(Triple(0xF7, 0xBF, 0x59), PeeringColors.caution)
        assertOpaque(Triple(0x5C, 0xD1, 0x82), PeeringColors.added)
    }

    @Test
    fun translucentTokensAreWhiteAtDesignOpacities() {
        assertEquals(Triple(0xFF, 0xFF, 0xFF), PeeringColors.surface.rgb())
        assertEquals(0.07f, PeeringColors.surface.alpha, 0.005f)
        assertEquals(0.08f, PeeringColors.hairline.alpha, 0.005f)
        assertEquals(0.62f, PeeringColors.muted.alpha, 0.005f)
        assertEquals(0.46f, PeeringColors.faint.alpha, 0.005f)
    }

    @Test
    fun colourSchemeIsDarkBackedByTheBackdrop() {
        val scheme = peeringColorScheme()
        assertEquals(PeeringColors.backdrop, scheme.background)
        assertEquals(PeeringColors.backdrop, scheme.surface)
        assertEquals(PeeringColors.ink, scheme.onSurface)
        assertEquals(PeeringColors.hairline, scheme.outline)
    }
}

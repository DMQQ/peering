package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.sessionmode.TrackpadSwipe

class PictureGesturesTest {
    private val gestures = PictureGestures()

    @Test
    fun `a finger held still for the hold time right clicks where it landed`() {
        gestures.down(1, 100.0, 200.0, timeMs = 0)

        assertEquals(500L, gestures.holdRemaining(0))
        assertNull(gestures.holdElapsed(400))
        assertEquals(CanvasPoint(100.0, 200.0), gestures.holdElapsed(500))
        assertTrue(gestures.spent)
    }

    @Test
    fun `a finger that moves past the slop is no hold`() {
        gestures.down(1, 100.0, 100.0, timeMs = 0)
        gestures.move(1, 130.0, 100.0)

        assertTrue(gestures.travelled)
        assertNull(gestures.holdRemaining(600))
    }

    @Test
    fun `a quick two finger tap is a right click at the first finger`() {
        gestures.down(1, 100.0, 100.0, timeMs = 0)
        gestures.down(2, 200.0, 100.0, timeMs = 10)

        assertNull(gestures.up(2, timeMs = 100))
        assertEquals(PictureGestures.Outcome.SecondaryClick(CanvasPoint(100.0, 100.0)), gestures.up(1, timeMs = 120))
    }

    @Test
    fun `two fingers that scroll are no tap`() {
        gestures.down(1, 100.0, 100.0, timeMs = 0)
        gestures.down(2, 200.0, 100.0, timeMs = 0)
        gestures.move(1, 100.0, 160.0)

        gestures.up(2, timeMs = 100)
        assertNull(gestures.up(1, timeMs = 100))
    }

    @Test
    fun `two fingers held too long are no tap`() {
        gestures.down(1, 100.0, 100.0, timeMs = 0)
        gestures.down(2, 200.0, 100.0, timeMs = 0)

        gestures.up(2, timeMs = 400)
        assertNull(gestures.up(1, timeMs = 400))
    }

    @Test
    fun `three fingers moving left swipe left once all lift`() {
        listOf(1, 2, 3).forEach { gestures.down(it, 300.0 + it * 50, 300.0, timeMs = 0) }
        assertTrue(gestures.swiping)
        listOf(1, 2, 3).forEach { gestures.move(it, 200.0 + it * 50, 310.0) }

        assertNull(gestures.up(1, timeMs = 100))
        assertNull(gestures.up(2, timeMs = 100))
        assertEquals(PictureGestures.Outcome.Swipe(TrackpadSwipe.LEFT), gestures.up(3, timeMs = 100))
    }

    @Test
    fun `four fingers moving up swipe up`() {
        listOf(1, 2, 3, 4).forEach { gestures.down(it, 100.0 * it, 500.0, timeMs = 0) }
        listOf(1, 2, 3, 4).forEach { gestures.move(it, 100.0 * it, 400.0) }

        listOf(1, 2, 3).forEach { gestures.up(it, timeMs = 100) }
        assertEquals(PictureGestures.Outcome.Swipe(TrackpadSwipe.UP), gestures.up(4, timeMs = 100))
    }

    @Test
    fun `three fingers that barely move are no swipe`() {
        listOf(1, 2, 3).forEach { gestures.down(it, 100.0 * it, 500.0, timeMs = 0) }
        listOf(1, 2, 3).forEach { gestures.move(it, 100.0 * it, 510.0) }

        listOf(1, 2).forEach { gestures.up(it, timeMs = 100) }
        assertNull(gestures.up(3, timeMs = 100))
    }

    @Test
    fun `the swipe threshold grows with the screen density`() {
        gestures.pixelsPerDp = 3.0
        listOf(1, 2, 3).forEach { gestures.down(it, 100.0 * it, 500.0, timeMs = 0) }
        listOf(1, 2, 3).forEach { gestures.move(it, 100.0 * it, 400.0) }

        listOf(1, 2).forEach { gestures.up(it, timeMs = 100) }
        assertNull(gestures.up(3, timeMs = 100))
    }
}

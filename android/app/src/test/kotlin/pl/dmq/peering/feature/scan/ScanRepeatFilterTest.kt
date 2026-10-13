package pl.dmq.peering.feature.scan

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanRepeatFilterTest {
    @Test
    fun aCodeIsLetThroughOnceWhileItStaysInView() {
        val filter = ScanRepeatFilter(quietMillis = 2_000)

        assertTrue(filter.accept("A", nowMillis = 0))
        assertFalse(filter.accept("A", nowMillis = 500))
        assertFalse(filter.accept("A", nowMillis = 1_900))
    }

    @Test
    fun aCodeSeenAgainAfterTheQuietWindowIsLetThroughAgain() {
        val filter = ScanRepeatFilter(quietMillis = 2_000)

        assertTrue(filter.accept("A", nowMillis = 0))
        assertTrue(filter.accept("A", nowMillis = 2_500))
    }

    @Test
    fun aDifferentCodeIsLetThroughStraightAway() {
        val filter = ScanRepeatFilter(quietMillis = 2_000)

        assertTrue(filter.accept("A", nowMillis = 0))
        assertTrue(filter.accept("B", nowMillis = 100))
    }

    @Test
    fun eachSightingRestartsTheQuietWindow() {
        val filter = ScanRepeatFilter(quietMillis = 2_000)

        assertTrue(filter.accept("A", nowMillis = 0))
        assertFalse(filter.accept("A", nowMillis = 1_500))
        assertFalse(filter.accept("A", nowMillis = 3_000))
    }
}

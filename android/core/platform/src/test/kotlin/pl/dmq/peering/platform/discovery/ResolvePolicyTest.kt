package pl.dmq.peering.platform.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ResolvePolicyTest {
    @Test
    fun anActiveResolveIsRetriedWithGrowingWaits() {
        assertEquals(250L, ResolvePolicy.retryDelayMillis(ResolvePolicy.FAILURE_ALREADY_ACTIVE, 0))
        assertEquals(500L, ResolvePolicy.retryDelayMillis(ResolvePolicy.FAILURE_ALREADY_ACTIVE, 1))
    }

    @Test
    fun retriesStopAfterAFewAttempts() {
        assertNull(ResolvePolicy.retryDelayMillis(ResolvePolicy.FAILURE_ALREADY_ACTIVE, 4))
    }

    @Test
    fun anInternalErrorIsRetriedOnce() {
        assertEquals(250L, ResolvePolicy.retryDelayMillis(ResolvePolicy.FAILURE_INTERNAL_ERROR, 0))
        assertNull(ResolvePolicy.retryDelayMillis(ResolvePolicy.FAILURE_INTERNAL_ERROR, 1))
    }

    @Test
    fun anUnknownCodeIsNotRetried() {
        assertNull(ResolvePolicy.retryDelayMillis(99, 0))
    }
}

package pl.dmq.peering.widget

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class SurvivingCollectTest {
    @Test
    fun anExceptionFromTheActionDoesNotEndCollection() = runTest {
        val seen = mutableListOf<Int>()
        var failures = 0
        var attempts = 0
        flow {
            attempts++
            emit(attempts)
        }.collectSurvivingFailures(retryDelayMillis = 1, onFailure = { failures++ }) {
            seen += it
            if (it < 3) throw IllegalArgumentException("bad snapshot")
        }

        assertEquals(listOf(1, 2, 3), seen)
        assertEquals(2, failures)
    }

    @Test
    fun anExceptionFromTheFlowIsSurvivedToo() = runTest {
        var attempts = 0
        var failures = 0
        val seen = mutableListOf<Int>()
        flow {
            attempts++
            if (attempts == 1) throw IllegalStateException("source failed")
            emit(attempts)
        }.collectSurvivingFailures(retryDelayMillis = 1, onFailure = { failures++ }) { seen += it }

        assertEquals(listOf(2), seen)
        assertEquals(1, failures)
    }

    @Test
    fun cancellationStillPropagates() = runTest {
        var propagated = false
        try {
            flow { emit(1) }.collectSurvivingFailures(onFailure = {}) { throw CancellationException("stop") }
        } catch (_: CancellationException) {
            propagated = true
        }

        assertEquals(true, propagated)
    }
}

package pl.dmq.peering

import kotlin.coroutines.EmptyCoroutineContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SurvivableErrorsTest {
    @Test
    fun anOrdinaryFailureIsLoggedAndContained() {
        val logged = mutableListOf<Throwable>()
        val failure = IllegalStateException("NSD discovery failed")

        survivableErrorHandler(logged::add).handleException(EmptyCoroutineContext, failure)

        assertEquals(listOf<Throwable>(failure), logged)
    }

    @Test
    fun anOutOfMemoryErrorStillEndsTheProcess() {
        val logged = mutableListOf<Throwable>()

        try {
            survivableErrorHandler(logged::add).handleException(EmptyCoroutineContext, OutOfMemoryError())
            fail("expected the error to be thrown again")
        } catch (error: OutOfMemoryError) {
            assertTrue(logged.isEmpty())
        }
    }
}

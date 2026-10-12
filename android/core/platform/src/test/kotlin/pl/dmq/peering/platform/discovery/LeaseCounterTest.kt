package pl.dmq.peering.platform.discovery

import org.junit.Assert.assertEquals
import org.junit.Test

class LeaseCounterTest {
    private var acquired = 0
    private var released = 0
    private val counter = LeaseCounter(onFirst = { acquired++ }, onLast = { released++ })

    @Test
    fun firstAcquireTakesTheLockOnce() {
        counter.acquire()
        counter.acquire()

        assertEquals(1, acquired)
    }

    @Test
    fun oneCollectorFinishingKeepsTheLockForTheOther() {
        counter.acquire()
        counter.acquire()

        counter.release()

        assertEquals(0, released)
    }

    @Test
    fun lastReleaseFreesTheLock() {
        counter.acquire()
        counter.acquire()

        counter.release()
        counter.release()

        assertEquals(1, released)
    }

    @Test
    fun releasingWithNothingHeldDoesNothing() {
        counter.release()
        counter.acquire()
        counter.release()
        counter.release()

        assertEquals(1, released)
    }
}

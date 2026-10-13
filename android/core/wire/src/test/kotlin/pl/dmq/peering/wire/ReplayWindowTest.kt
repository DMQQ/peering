package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayWindowTest {
    @Test
    fun followsTheSharedVectorSteps() {
        val vector = VectorFiles.load("crypto.json").jsonObject["replayWindow"]!!.jsonObject
        assertEquals(64L, vector.long("size"))
        val window = ReplayWindow()
        for (step in vector["steps"]!!.jsonArray) {
            val item = step.jsonObject
            val counter = item.long("counter").toULong()
            assertEquals("counter $counter", item.bool("accepts"), window.accepts(counter))
            if (item["commit"]?.jsonPrimitive?.content == "true") window.commit(counter)
        }
    }

    @Test
    fun aForgedJumpDoesNotPoisonTheWindow() {
        val window = ReplayWindow()
        window.commit(10uL)
        assertTrue(window.accepts(ULong.MAX_VALUE))
        assertTrue("the check alone moved nothing", window.accepts(11uL))
    }

    @Test
    fun aJumpWiderThanTheWindowForgetsOldCounters() {
        val window = ReplayWindow()
        window.commit(1uL)
        window.commit(1000uL)
        assertFalse("far behind the window", window.accepts(1uL))
        assertTrue(window.accepts(999uL))
    }

    @Test
    fun aDuplicateInsideTheWindowIsRefused() {
        val window = ReplayWindow()
        window.commit(50uL)
        window.commit(40uL)
        assertFalse(window.accepts(40uL))
        assertFalse(window.accepts(50uL))
    }

    @Test
    fun aLateDatagramInsideTheWindowIsAcceptedOnce() {
        val window = ReplayWindow()
        window.commit(20uL)
        window.commit(18uL)
        assertTrue(window.accepts(19uL))
        window.commit(19uL)
        assertFalse(window.accepts(19uL))
    }

    @Test
    fun theOldestCounterInsideTheWindowIsStillAccepted() {
        val window = ReplayWindow()
        window.commit(64uL)
        assertTrue(window.accepts(1uL))
        assertFalse(window.accepts(0uL))
    }

    @Test
    fun committingACounterOutsideTheWindowLeavesTheBitmapAlone() {
        val window = ReplayWindow()
        window.commit(100uL)
        window.commit(10uL)
        assertFalse(window.accepts(10uL))
        assertTrue(window.accepts(99uL))
    }

    @Test
    fun resetAcceptsAnythingAgain() {
        val window = ReplayWindow()
        window.commit(9uL)
        window.reset()
        assertTrue(window.accepts(9uL))
    }

    private fun JsonObject.long(name: String): Long =
        this[name]!!.jsonPrimitive.content.toLong()

    private fun JsonObject.bool(name: String): Boolean =
        this[name]!!.jsonPrimitive.content.toBoolean()
}

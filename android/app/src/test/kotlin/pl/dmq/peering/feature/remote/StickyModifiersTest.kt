package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.Modifiers

class StickyModifiersTest {
    private val modifiers = StickyModifiers()

    @Test
    fun `one tap latches the modifier and presses it on the Mac`() {
        val commands = modifiers.tap(StickyModifier.COMMAND, timeMs = 0)

        assertEquals(listOf(KeyDown(55, Modifiers(Modifiers.COMMAND))), commands)
        assertEquals(ModifierLatch.LATCHED, modifiers.latches().getValue(StickyModifier.COMMAND))
    }

    @Test
    fun `the next key releases a latched modifier`() {
        modifiers.tap(StickyModifier.COMMAND, timeMs = 0)

        val released = modifiers.afterKey()

        assertEquals(listOf(KeyUp(55, Modifiers(0))), released)
        assertEquals(ModifierLatch.OFF, modifiers.latches().getValue(StickyModifier.COMMAND))
    }

    @Test
    fun `a second tap inside the double tap window locks the modifier through the next key`() {
        modifiers.tap(StickyModifier.SHIFT, timeMs = 0)

        val second = modifiers.tap(StickyModifier.SHIFT, timeMs = StickyModifiers.DOUBLE_TAP_MS)
        val afterKey = modifiers.afterKey()

        assertTrue(second.isEmpty())
        assertTrue(afterKey.isEmpty())
        assertEquals(ModifierLatch.LOCKED, modifiers.latches().getValue(StickyModifier.SHIFT))
    }

    @Test
    fun `a second tap after the window is a plain release, not a lock`() {
        modifiers.tap(StickyModifier.SHIFT, timeMs = 0)

        val second = modifiers.tap(StickyModifier.SHIFT, timeMs = StickyModifiers.DOUBLE_TAP_MS + 1)

        assertEquals(listOf(KeyUp(56, Modifiers(0))), second)
        assertEquals(ModifierLatch.OFF, modifiers.latches().getValue(StickyModifier.SHIFT))
    }

    @Test
    fun `a locked modifier is released by its next tap`() {
        modifiers.tap(StickyModifier.OPTION, timeMs = 0)
        modifiers.tap(StickyModifier.OPTION, timeMs = 100)

        val released = modifiers.tap(StickyModifier.OPTION, timeMs = 5_000)

        assertEquals(listOf(KeyUp(58, Modifiers(0))), released)
        assertEquals(ModifierLatch.OFF, modifiers.latches().getValue(StickyModifier.OPTION))
    }

    @Test
    fun `active modifiers combine into one set of flags`() {
        modifiers.tap(StickyModifier.SHIFT, timeMs = 0)
        modifiers.tap(StickyModifier.COMMAND, timeMs = 10)

        assertEquals(Modifiers(Modifiers.SHIFT or Modifiers.COMMAND), modifiers.activeModifiers())
        assertTrue(modifiers.hasActive())
    }

    @Test
    fun `a key with nothing latched releases nothing`() {
        assertTrue(modifiers.afterKey().isEmpty())
        assertEquals(Modifiers(0), modifiers.activeModifiers())
    }
}

package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.RemoteCommand

/**
 * Tap-to-latch modifiers. A tap holds the modifier on the Mac until the next key; a second tap inside [DOUBLE_TAP_MS]
 * locks it until tapped again. Each change is a real key press on the Mac, because a flag on the next keystroke is not
 * the same thing to every app. Not thread safe.
 */
class StickyModifiers {
    private val latches = StickyModifier.entries.associateWith { ModifierLatch.OFF }.toMutableMap()
    private val lastTapMs = mutableMapOf<StickyModifier, Long>()

    fun latches(): Map<StickyModifier, ModifierLatch> = latches.toMap()

    fun activeModifiers(): Modifiers = Modifiers(
        StickyModifier.entries
            .filter { latches.getValue(it) != ModifierLatch.OFF }
            .fold(0L) { bits, modifier -> bits or modifier.bit },
    )

    fun hasActive(): Boolean = latches.values.any { it != ModifierLatch.OFF }

    fun tap(modifier: StickyModifier, timeMs: Long): List<RemoteCommand> {
        val before = latches.getValue(modifier)
        val after = when (before) {
            ModifierLatch.OFF -> ModifierLatch.LATCHED
            ModifierLatch.LATCHED -> if (isDoubleTap(modifier, timeMs)) ModifierLatch.LOCKED else ModifierLatch.OFF
            ModifierLatch.LOCKED -> ModifierLatch.OFF
        }
        latches[modifier] = after
        lastTapMs[modifier] = timeMs
        return when {
            before == ModifierLatch.OFF -> listOf(KeyDown(modifier.keyCode, activeModifiers()))
            after == ModifierLatch.OFF -> listOf(KeyUp(modifier.keyCode, activeModifiers()))
            else -> emptyList()
        }
    }

    /** Releases every latch that was for one key. Locked modifiers stay down. */
    fun afterKey(): List<RemoteCommand> {
        val released = latches.filterValues { it == ModifierLatch.LATCHED }.keys
        released.forEach { latches[it] = ModifierLatch.OFF }
        return released.map { KeyUp(it.keyCode, activeModifiers()) }
    }

    private fun isDoubleTap(modifier: StickyModifier, timeMs: Long): Boolean {
        val previous = lastTapMs[modifier] ?: return false
        return timeMs - previous <= DOUBLE_TAP_MS
    }

    companion object {
        const val DOUBLE_TAP_MS = 350L
    }
}

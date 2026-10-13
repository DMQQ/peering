package pl.dmq.peering.testing

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.ConcurrentHashMap

/**
 * What the debug test harness can read and drive. Screens register a [Slot] while they are on screen; in a release build
 * nothing registers, so the table stays empty. Every call comes on the main thread.
 */
object TestBridge {
    class Slot(
        val state: () -> Map<String, Any?> = { emptyMap() },
        val actions: Map<String, (String?) -> Unit> = emptyMap(),
    )

    private val slots = ConcurrentHashMap<String, Slot>()
    private val mainThread by lazy { Handler(Looper.getMainLooper()) }
    private var framesReceived = 0L
    private var lastFrameAt = 0L

    /** Returns the call that removes the slot again. */
    fun register(name: String, slot: Slot): () -> Unit {
        slots[name] = slot
        return { slots.remove(name, slot) }
    }

    fun frameArrived() {
        framesReceived++
        lastFrameAt = SystemClock.elapsedRealtime()
    }

    fun snapshot(): Map<String, Any?> {
        val merged = LinkedHashMap<String, Any?>()
        slots.toSortedMap().values.forEach { slot -> merged.putAll(runCatching { slot.state() }.getOrDefault(emptyMap())) }
        merged["framesReceived"] = framesReceived
        merged["lastFrameAgeMs"] = if (lastFrameAt == 0L) null else SystemClock.elapsedRealtime() - lastFrameAt
        return merged
    }

    /** Runs [action] on the first slot that offers it; false when no screen on display does. */
    fun invoke(action: String, argument: String?): Boolean {
        val handler = slots.values.firstNotNullOfOrNull { it.actions[action] } ?: return false
        handler(argument)
        return true
    }

    /** For an action whose screen is still opening: tries again until it appears or [timeoutMs] passes. */
    fun invokeWhenAvailable(action: String, argument: String?, timeoutMs: Long = RETRY_WINDOW_MS) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        object : Runnable {
            override fun run() {
                if (!invoke(action, argument) && SystemClock.elapsedRealtime() < deadline) mainThread.postDelayed(this, RETRY_STEP_MS)
            }
        }.run()
    }

    private const val RETRY_WINDOW_MS = 3_000L
    private const val RETRY_STEP_MS = 50L
}

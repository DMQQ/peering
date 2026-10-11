package pl.dmq.peering.wire

/**
 * Datagram replay window of 64 with a bitmap. [accepts] does not mutate: a forged datagram with a huge counter must
 * not drag the window. Call [commit] only after the datagram authenticated.
 */
class ReplayWindow {
    private var highest: ULong = 0u
    private var seen: Long = 0L
    private var started = false

    fun accepts(counter: ULong): Boolean {
        if (!started || counter > highest) return true
        val distance = highest - counter
        return distance < WINDOW_SIZE && seen and (1L shl distance.toInt()) == 0L
    }

    fun commit(counter: ULong) {
        if (!started) {
            started = true
            highest = counter
            seen = 1L
            return
        }
        if (counter > highest) {
            val shift = counter - highest
            seen = if (shift >= WINDOW_SIZE) 0L else seen shl shift.toInt()
            seen = seen or 1L
            highest = counter
        } else {
            val distance = highest - counter
            if (distance < WINDOW_SIZE) seen = seen or (1L shl distance.toInt())
        }
    }

    fun reset() {
        highest = 0u
        seen = 0L
        started = false
    }

    companion object {
        const val WINDOW_SIZE: ULong = 64u
    }
}

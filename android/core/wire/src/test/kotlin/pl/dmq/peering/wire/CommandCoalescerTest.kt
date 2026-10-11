package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Test

class CommandCoalescerTest {
    private sealed class Command {
        data class Move(val x: Int, val y: Int) : Command()

        data class Scroll(val dy: Int) : Command()

        data class Press(val button: Int) : Command()

        data class Release(val button: Int) : Command()
    }

    private fun coalescer() = CommandCoalescer<Command>(
        policy = { command ->
            when (command) {
                is Command.Move -> Coalescing.REPLACE_LATEST
                is Command.Scroll -> Coalescing.ACCUMULATE
                is Command.Press, is Command.Release -> Coalescing.NONE
            }
        },
        merge = { older, newer ->
            if (older is Command.Scroll && newer is Command.Scroll) Command.Scroll(older.dy + newer.dy) else newer
        },
    )

    @Test
    fun aQueuedMoveIsReplacedByTheNewestMove() {
        val queue = coalescer()
        queue.offer(Command.Move(1, 1))
        queue.offer(Command.Move(2, 2))
        queue.offer(Command.Move(3, 3))
        assertEquals(listOf(Command.Move(3, 3)), queue.drain())
    }

    @Test
    fun queuedScrollsAreSummed() {
        val queue = coalescer()
        queue.offer(Command.Scroll(1))
        queue.offer(Command.Scroll(2))
        queue.offer(Command.Scroll(-5))
        assertEquals(listOf(Command.Scroll(-2)), queue.drain())
    }

    @Test
    fun buttonEventsAreNeverDroppedOrReordered() {
        val queue = coalescer()
        queue.offer(Command.Move(1, 1))
        queue.offer(Command.Press(1))
        queue.offer(Command.Move(2, 2))
        queue.offer(Command.Press(1))
        queue.offer(Command.Release(1))
        assertEquals(
            listOf(
                Command.Move(1, 1),
                Command.Press(1),
                Command.Move(2, 2),
                Command.Press(1),
                Command.Release(1),
            ),
            queue.drain(),
        )
    }

    @Test
    fun aMergeNeverJumpsOverAnItemQueuedAfterIt() {
        val queue = coalescer()
        queue.offer(Command.Scroll(1))
        queue.offer(Command.Move(4, 4))
        queue.offer(Command.Scroll(2))
        assertEquals(listOf(Command.Scroll(1), Command.Move(4, 4), Command.Scroll(2)), queue.drain())
    }

    @Test
    fun interleavedCommandsKeepArrivalOrderAndCoalesceOnlyNeighbours() {
        val queue = coalescer()
        queue.offer(Command.Move(1, 1))
        queue.offer(Command.Scroll(1))
        queue.offer(Command.Scroll(2))
        queue.offer(Command.Move(5, 5))
        queue.offer(Command.Press(1))
        queue.offer(Command.Move(6, 6))
        queue.offer(Command.Move(7, 7))
        queue.offer(Command.Scroll(3))
        assertEquals(
            listOf(
                Command.Move(1, 1),
                Command.Scroll(3),
                Command.Move(5, 5),
                Command.Press(1),
                Command.Move(7, 7),
                Command.Scroll(3),
            ),
            queue.drain(),
        )
    }

    @Test
    fun drainEmptiesTheQueue() {
        val queue = coalescer()
        queue.offer(Command.Press(2))
        assertEquals(listOf(Command.Press(2)), queue.drain())
        assertEquals(emptyList<Command>(), queue.drain())
    }

    @Test
    fun aReleaseAfterAPressIsKeptWithItsPair() {
        val queue = coalescer()
        queue.offer(Command.Press(1))
        queue.offer(Command.Release(1))
        queue.offer(Command.Press(1))
        assertEquals(listOf(Command.Press(1), Command.Release(1), Command.Press(1)), queue.drain())
    }
}

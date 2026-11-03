package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test

class DictationSpliceTest {
    @Test
    fun heardWordsGoAfterWhatWasTyped() {
        val splice = DictationSplice("fix")
        assertEquals("fix the", splice.apply("fix", "the"))
        assertEquals("fix the build", splice.apply("fix the", "the build"))
    }

    @Test
    fun typingAfterTheWordsWhileListeningIsKept() {
        val splice = DictationSplice("")
        val first = splice.apply("", "hello")
        assertEquals("hello world!", splice.apply("$first!", "hello world"))
    }

    @Test
    fun typingBeforeTheWordsWhileListeningIsKept() {
        val splice = DictationSplice("note:")
        val first = splice.apply("note:", "buy")
        assertEquals("my note: buy milk", splice.apply("my $first", "buy milk"))
    }

    @Test
    fun anEditInsideTheWordsWinsAndLaterWordsFollowIt() {
        val splice = DictationSplice("")
        splice.apply("", "helo")
        assertEquals("hello", splice.apply("hello", "helo"))
        assertEquals("hello there", splice.apply("hello", "helo there"))
    }
}

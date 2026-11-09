package pl.dmq.peering.session.video

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyframeRequestPolicyTest {
    private val policy = KeyframeRequestPolicy()

    @Test
    fun aDropAtTheStartOfAWaitDoesNotAsk() {
        assertFalse(policy.noteDrop(10.0))
        assertFalse(policy.noteDrop(10.2))
    }

    @Test
    fun aWaitPastTheGraceAsksOnce() {
        policy.noteDrop(10.0)
        assertTrue(policy.noteDrop(10.3))
        assertFalse(policy.noteDrop(10.5))
    }

    @Test
    fun aWaitThatOutlastsTheCooldownAsksAgain() {
        policy.noteDrop(10.0)
        assertTrue(policy.noteDrop(10.4))
        assertFalse(policy.noteDrop(11.3))
        assertTrue(policy.noteDrop(11.4))
    }

    @Test
    fun recoveringStartsTheGraceOver() {
        policy.noteDrop(10.0)
        policy.noteRecovered()
        assertFalse(policy.noteDrop(20.0))
        assertFalse(policy.noteDrop(20.2))
        assertTrue(policy.noteDrop(20.3))
    }
}

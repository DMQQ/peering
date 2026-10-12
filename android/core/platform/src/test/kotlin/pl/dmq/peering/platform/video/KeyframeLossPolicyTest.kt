package pl.dmq.peering.platform.video

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyframeLossPolicyTest {
    private val policy = KeyframeLossPolicy()

    @Test
    fun aNewDecoderTakesNothingBeforeAKeyframe() {
        assertFalse(policy.admit(isKeyframe = false))
        assertTrue(policy.admit(isKeyframe = true))
        assertTrue(policy.admit(isKeyframe = false))
    }

    @Test
    fun aDroppedInputFlushesAndSkipsUntilTheNextKeyframe() {
        policy.admit(isKeyframe = true)

        assertTrue(policy.onInputDropped())

        assertFalse(policy.admit(isKeyframe = false))
        assertFalse(policy.admit(isKeyframe = false))
        assertTrue(policy.admit(isKeyframe = true))
    }

    @Test
    fun aCodecErrorFlushesAndWaitsForAKeyframe() {
        policy.admit(isKeyframe = true)

        assertTrue(policy.onDecodeError())

        assertFalse(policy.admit(isKeyframe = false))
        assertTrue(policy.admit(isKeyframe = true))
    }

    @Test
    fun aConfigChangeWaitsForAKeyframeWithoutAFlush() {
        policy.admit(isKeyframe = true)

        policy.onConfigChanged()

        assertFalse(policy.admit(isKeyframe = false))
        assertTrue(policy.admit(isKeyframe = true))
    }
}

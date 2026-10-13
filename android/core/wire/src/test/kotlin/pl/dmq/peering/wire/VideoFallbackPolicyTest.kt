package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.VideoFallbackPolicy.Decision

class VideoFallbackPolicyTest {
    private fun VideoFallbackPolicy.step(
        now: Double,
        lastPictureAt: Double?,
        lastControlReplyAt: Double? = now,
        applies: Boolean = true,
    ): Decision = advance(now, lastPictureAt, lastControlReplyAt, applies)

    /** Enters fallback at t = 3.0 from a last picture at t = 0.0, with the control channel answering. */
    private fun fallenBackAtThree(): VideoFallbackPolicy {
        val policy = VideoFallbackPolicy()
        assertEquals(Decision.USE_CONTROL_CHANNEL, policy.step(3.0, lastPictureAt = 0.0))
        return policy
    }

    @Test
    fun noFallbackBeforeThreeSecondsOfSilence() {
        val cases = listOf(
            2.9 to Decision.NONE,
            3.0 to Decision.USE_CONTROL_CHANNEL,
        )
        for ((now, expected) in cases) {
            val policy = VideoFallbackPolicy()
            assertEquals("at $now", expected, policy.step(now, lastPictureAt = 0.0))
        }
    }

    @Test
    fun noFallbackWithoutAPictureOrWhileTheControlChannelIsSilent() {
        val withoutPicture = VideoFallbackPolicy()
        assertEquals(Decision.NONE, withoutPicture.step(now = 3.0, lastPictureAt = null))

        val replyAgeCases = listOf(
            5.1 to Decision.NONE,
            5.0 to Decision.USE_CONTROL_CHANNEL,
        )
        for ((replyAge, expected) in replyAgeCases) {
            val policy = VideoFallbackPolicy()
            val now = 10.0
            assertEquals("reply age $replyAge", expected, policy.step(now, 0.0, lastControlReplyAt = now - replyAge))
        }

        val neverReplied = VideoFallbackPolicy()
        assertEquals(Decision.NONE, neverReplied.step(now = 3.0, lastPictureAt = 0.0, lastControlReplyAt = null))
    }

    @Test
    fun aRequestIsRepeatedEveryFiveSecondsWhileNoPictureArrives() {
        val policy = fallenBackAtThree()
        assertTrue(policy.isFallback)

        val expectedByTime = listOf(
            4.0 to Decision.NONE,
            7.9 to Decision.NONE,
            8.0 to Decision.USE_CONTROL_CHANNEL,
            12.9 to Decision.NONE,
            13.0 to Decision.USE_CONTROL_CHANNEL,
        )
        for ((now, expected) in expectedByTime) {
            assertEquals("at $now", expected, policy.step(now, lastPictureAt = 0.0))
        }
    }

    @Test
    fun aPictureSinceTheLastRequestStopsTheRepeats() {
        val policy = fallenBackAtThree()

        assertEquals(Decision.NONE, policy.step(8.0, lastPictureAt = 7.0))
    }

    @Test
    fun returnsToPrimaryAfterFiveSecondsAndTwoPrimaryPictures() {
        val policy = fallenBackAtThree()
        policy.notePrimaryPicture()

        assertEquals(Decision.NONE, policy.step(8.0, lastPictureAt = 7.5))
        policy.notePrimaryPicture()
        assertEquals(Decision.USE_PRIMARY_TRANSPORT, policy.step(8.0, lastPictureAt = 7.5))
        assertFalse(policy.isFallback)
    }

    @Test
    fun holdIsNotShortenedByPicturesArrivingEarly() {
        val policy = fallenBackAtThree()
        policy.notePrimaryPicture()
        policy.notePrimaryPicture()

        assertEquals(Decision.NONE, policy.step(7.9, lastPictureAt = 7.5))
        assertEquals(Decision.USE_PRIMARY_TRANSPORT, policy.step(8.0, lastPictureAt = 7.5))
    }

    @Test
    fun aReturnStartsTheRepeatIntervalBeforeAnotherFallback() {
        val policy = fallenBackAtThree()
        policy.notePrimaryPicture()
        policy.notePrimaryPicture()
        policy.step(8.0, lastPictureAt = 7.5)

        assertEquals(Decision.NONE, policy.step(10.0, lastPictureAt = 0.0, lastControlReplyAt = 9.9))
        assertEquals(Decision.USE_CONTROL_CHANNEL, policy.step(13.0, lastPictureAt = 0.0, lastControlReplyAt = 12.9))
    }

    @Test
    fun appliesFalseGivesNoneEvenWhenFallbackIsDue() {
        val policy = VideoFallbackPolicy()

        assertEquals(Decision.NONE, policy.step(3.0, lastPictureAt = 0.0, applies = false))
        assertFalse(policy.isFallback)

        val fallen = fallenBackAtThree()
        assertEquals(Decision.NONE, fallen.step(20.0, lastPictureAt = 7.5, applies = false))
        assertTrue(fallen.isFallback)
    }

    @Test
    fun primaryPicturesOnlyCountWhileInFallback() {
        val policy = VideoFallbackPolicy()
        policy.notePrimaryPicture()
        policy.notePrimaryPicture()
        policy.step(3.0, lastPictureAt = 0.0)

        assertEquals(Decision.NONE, policy.step(8.0, lastPictureAt = 7.5))
    }

    @Test
    fun resetForgetsTheFallbackAndItsRequestTimer() {
        val policy = fallenBackAtThree()
        policy.reset()

        assertFalse(policy.isFallback)
        assertEquals(Decision.USE_CONTROL_CHANNEL, policy.step(3.0, lastPictureAt = 0.0))
    }
}

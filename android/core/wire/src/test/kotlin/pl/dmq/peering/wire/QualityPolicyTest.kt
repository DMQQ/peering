package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QualityPolicyTest {
    private fun observeAll(policy: AutoQualityPolicy, latency: Double, dropped: Int, times: Int): List<QualityTier?> =
        List(times) { policy.observe(latency, dropped) }

    @Test
    fun aBitrateRequestOfZeroOrLessIsNotABitrate() {
        assertNull(clampedBitrateKbps(0))
        assertNull(clampedBitrateKbps(-5))
    }

    @Test
    fun aBitrateRequestIsCappedAtTheMaximum() {
        assertEquals(8_000, clampedBitrateKbps(8_000))
        assertEquals(MAX_BITRATE_KBPS, clampedBitrateKbps(250_000))
        assertEquals(MAX_BITRATE_KBPS, clampedBitrateKbps(Long.MAX_VALUE))
    }

    @Test
    fun defaultBitrateFollowsThePixelRateFormula() {
        assertEquals(14_929_920, defaultBitrateBps(1920, 1080, 60))
    }

    @Test
    fun defaultBitrateIsRaisedToTheFloorAndCappedAtTheCeiling() {
        assertEquals(4_000_000, defaultBitrateBps(640, 360, 30))
        assertEquals(30_000_000, defaultBitrateBps(7680, 4320, 60))
    }

    @Test
    fun tierLookupPicksTheHighestTierNotAboveTheValue() {
        assertNull(QualityTier.fromKbps(1_999))
        assertEquals(QualityTier.LOW, QualityTier.fromKbps(2_000))
        assertEquals(QualityTier.LOW, QualityTier.fromKbps(7_999))
        assertEquals(QualityTier.MEDIUM, QualityTier.fromKbps(8_000))
        assertEquals(QualityTier.MEDIUM, QualityTier.fromKbps(19_999))
        assertEquals(QualityTier.HIGH, QualityTier.fromKbps(100_000))
    }

    @Test
    fun aDirectOrLanPathStartsAtHighAndARelayAtMedium() {
        assertEquals(QualityTier.HIGH, AutoQualityPolicy(AutoQualityPolicy.Path.LAN).tier)
        assertEquals(QualityTier.HIGH, AutoQualityPolicy(AutoQualityPolicy.Path.DIRECT).tier)
        assertEquals(QualityTier.MEDIUM, AutoQualityPolicy(AutoQualityPolicy.Path.RELAY).tier)
    }

    @Test
    fun aCeilingCapsTheStartingTier() {
        assertEquals(QualityTier.MEDIUM, AutoQualityPolicy(AutoQualityPolicy.Path.LAN, QualityTier.MEDIUM).tier)
    }

    @Test
    fun aSlowSampleStepsDownOneTier() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN)
        assertEquals(QualityTier.MEDIUM, policy.observe(200.0, 0))
        assertEquals(QualityTier.LOW, policy.observe(200.0, 0))
    }

    @Test
    fun aVeryHighLatencyOrThreeDroppedFramesDropsToLow() {
        assertEquals(QualityTier.LOW, AutoQualityPolicy(AutoQualityPolicy.Path.LAN).observe(400.0, 0))
        assertEquals(QualityTier.LOW, AutoQualityPolicy(AutoQualityPolicy.Path.LAN).observe(10.0, 3))
    }

    @Test
    fun aDroppedFrameStepsDownOneTier() {
        assertEquals(QualityTier.MEDIUM, AutoQualityPolicy(AutoQualityPolicy.Path.LAN).observe(10.0, 1))
    }

    @Test
    fun aMiddlingSampleNeitherFallsNorClimbs() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN)
        assertNull(policy.observe(100.0, 0))
        assertEquals(QualityTier.HIGH, policy.tier)
    }

    @Test
    fun climbingNeedsTwelveHealthySamplesInARow() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN)
        policy.observe(200.0, 0)
        val samples = observeAll(policy, latency = 50.0, dropped = 0, times = 12)
        assertEquals(List(11) { null } + listOf(QualityTier.HIGH), samples)
    }

    @Test
    fun aBadSampleRestartsTheHealthyCount() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN)
        policy.observe(200.0, 0)
        observeAll(policy, latency = 50.0, dropped = 0, times = 11)
        assertNull(policy.observe(100.0, 0))
        assertNull(policy.observe(50.0, 0))
        assertEquals(QualityTier.LOW, policy.observe(400.0, 0))
    }

    @Test
    fun aLanHealthySampleMustBeAtOrBelowSixtyFiveMilliseconds() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN)
        policy.observe(400.0, 0)
        assertNull(policy.observe(70.0, 0))
        assertEquals(QualityTier.LOW, policy.tier)
    }

    @Test
    fun aRelayHealthySampleMayBeUpToEightyMilliseconds() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.RELAY)
        policy.observe(400.0, 0)
        val samples = observeAll(policy, latency = 70.0, dropped = 0, times = 12)
        assertEquals(List(11) { null } + listOf(QualityTier.MEDIUM), samples)
    }

    @Test
    fun theClimbStopsAtTheCeilingAndNeverPassesIt() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN, QualityTier.MEDIUM)
        policy.observe(400.0, 0)
        val samples = observeAll(policy, latency = 10.0, dropped = 0, times = 24)
        assertEquals(QualityTier.MEDIUM, samples.last { it != null })
        assertEquals(QualityTier.MEDIUM, policy.tier)
    }

    @Test
    fun theLowestTierCannotFallFurther() {
        val policy = AutoQualityPolicy(AutoQualityPolicy.Path.LAN)
        policy.observe(400.0, 0)
        assertNull(policy.observe(400.0, 0))
    }
}

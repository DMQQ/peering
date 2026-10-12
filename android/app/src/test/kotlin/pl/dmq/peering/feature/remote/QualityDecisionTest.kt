package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.wire.QualityTier

class QualityDecisionTest {
    @Test
    fun autoIsAlwaysApplied() {
        assertEquals(QualityDecision.Apply(QualityChoice.Automatic), QualityDecision.of(StreamQuality.Auto, QualityTier.MEDIUM))
    }

    @Test
    fun aFixedLevelUpToTheCeilingIsApplied() {
        assertEquals(
            QualityDecision.Apply(QualityChoice.Fixed(QualityTier.MEDIUM)),
            QualityDecision.of(StreamQuality.Medium, QualityTier.MEDIUM),
        )
        assertEquals(
            QualityDecision.Apply(QualityChoice.Fixed(QualityTier.LOW)),
            QualityDecision.of(StreamQuality.Low, QualityTier.MEDIUM),
        )
    }

    @Test
    fun aFixedLevelAboveTheCeilingNeedsMoreRelayTime() {
        assertEquals(QualityDecision.NeedsUpgrade, QualityDecision.of(StreamQuality.High, QualityTier.MEDIUM))
    }

    @Test
    fun everyLevelIsAvailableWithoutACeiling() {
        assertEquals(
            QualityDecision.Apply(QualityChoice.Fixed(QualityTier.HIGH)),
            QualityDecision.of(StreamQuality.High, QualityTier.HIGH),
        )
    }
}

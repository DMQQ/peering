package pl.dmq.peering.feature.remote

import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.wire.QualityTier

/** What picking a quality does: apply it, or ask for relay time the phone does not have. */
sealed interface QualityDecision {
    data class Apply(val choice: QualityChoice) : QualityDecision

    data object NeedsUpgrade : QualityDecision

    companion object {
        /** A fixed level above the ceiling needs more relay time. Auto is never refused: the policy stays under the ceiling. */
        fun of(quality: StreamQuality, ceiling: QualityTier): QualityDecision {
            val tier = quality.tier() ?: return Apply(QualityChoice.Automatic)
            return if (tier > ceiling) NeedsUpgrade else Apply(QualityChoice.Fixed(tier))
        }

        private fun StreamQuality.tier(): QualityTier? = when (this) {
            StreamQuality.Auto -> null
            StreamQuality.Low -> QualityTier.LOW
            StreamQuality.Medium -> QualityTier.MEDIUM
            StreamQuality.High -> QualityTier.HIGH
        }
    }
}

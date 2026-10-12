package pl.dmq.peering.ui.wiring

import pl.dmq.peering.billing.Billing
import pl.dmq.peering.feature.settings.SettingsStore
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.session.controller.QualitySource
import pl.dmq.peering.wire.QualityTier

/** The stored default quality and the paid relay status, read by each session as it starts and as it changes. */
internal class PeeringQualitySource(
    private val settings: SettingsStore,
    private val billing: Billing,
) : QualitySource {
    override fun choice(): QualityChoice = settings.currentStreamQuality().toChoice()

    override fun unlimitedRelay(): Boolean = billing.paidRelay.value

    private fun StreamQuality.toChoice(): QualityChoice = when (this) {
        StreamQuality.Auto -> QualityChoice.Automatic
        StreamQuality.Low -> QualityChoice.Fixed(QualityTier.LOW)
        StreamQuality.Medium -> QualityChoice.Fixed(QualityTier.MEDIUM)
        StreamQuality.High -> QualityChoice.Fixed(QualityTier.HIGH)
    }
}

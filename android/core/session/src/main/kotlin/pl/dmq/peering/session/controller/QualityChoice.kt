package pl.dmq.peering.session.controller

import pl.dmq.peering.wire.QualityTier

/** What the user chose for the stream: the policy moves the rate, or the rate is held at one tier. */
sealed interface QualityChoice {
    data object Automatic : QualityChoice

    data class Fixed(val tier: QualityTier) : QualityChoice
}

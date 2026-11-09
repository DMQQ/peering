package pl.dmq.peering.session.controller

import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.QualityTier

/** The highest tier a session streams at. Only the local network reaches Ultra: a direct path can run over mobile data. A relayed session is held to Medium unless the phone has unlimited relay time, and so is any session while the phone saves power. */
object QualityCeiling {
    fun of(path: SessionRecord.Path, unlimitedRelay: Boolean, powerSaving: Boolean = false): QualityTier =
        PowerSaving.ceiling(
            when {
                path == SessionRecord.Path.LAN -> QualityTier.ULTRA
                path == SessionRecord.Path.DIRECT || unlimitedRelay -> QualityTier.HIGH
                else -> QualityTier.MEDIUM
            },
            powerSaving,
        )
}

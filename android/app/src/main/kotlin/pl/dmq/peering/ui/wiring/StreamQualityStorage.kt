package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.settings.StreamQuality

/** The name a preference stores for [quality]. Names, not ordinals, so a reordered enum cannot change a saved choice. */
internal fun StreamQuality.stored(): String = name

/** The quality a stored name stands for. Anything unknown reads as the default, Auto. */
internal fun storedStreamQuality(text: String?): StreamQuality =
    StreamQuality.entries.firstOrNull { it.name == text } ?: StreamQuality.Auto

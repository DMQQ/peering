package pl.dmq.peering.session.controller

import pl.dmq.peering.wire.QualityTier

/** How a phone that saves power changes the picture: a lower rate ceiling and a frame rate cap the computer applies to what it sends. */
object PowerSaving {
    val CEILING = QualityTier.MEDIUM
    const val FRAMES_PER_SECOND = 30

    /** The most a frame rate request may ask for: the computer clamps it to what it can do, so this lifts a cap. */
    const val UNCAPPED_FRAMES_PER_SECOND = 120

    fun ceiling(base: QualityTier, powerSaving: Boolean): QualityTier = if (powerSaving && base > CEILING) CEILING else base

    /**
     * The frame rate to ask for. 0 keeps what the computer has, which is right until a cap was set: leaving power saving
     * must lift it explicitly, because the computer holds the last one it was given.
     */
    fun framesPerSecond(powerSaving: Boolean, wasCapped: Boolean): Int = when {
        powerSaving -> FRAMES_PER_SECOND
        wasCapped -> UNCAPPED_FRAMES_PER_SECOND
        else -> 0
    }
}

package pl.dmq.peering.feature.settings

/** Replaces this device's identity. Every Mac must then be paired again. */
interface IdentityReset {
    /** False when the new identity could not be stored. */
    fun reset(): Boolean
}

package pl.dmq.peering.feature.remote

enum class ModifierLatch {
    OFF,

    /** Held for the next key only. */
    LATCHED,

    /** Held until tapped again. */
    LOCKED,
}

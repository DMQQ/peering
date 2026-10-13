package pl.dmq.peering.feature.remote

enum class InputMode {
    /** A finger moves a virtual cursor by its delta, as a laptop trackpad does. */
    TRACKPAD,

    /** The cursor goes under the finger, on the picture. */
    DIRECT,

    /** Touches only move and zoom the picture; nothing reaches the computer. */
    OBSERVE,
}

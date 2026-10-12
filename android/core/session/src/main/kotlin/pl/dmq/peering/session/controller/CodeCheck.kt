package pl.dmq.peering.session.controller

/** How the six digits the user gave compare with the ones the Mac shows. */
enum class CodeCheck {
    Match,
    Mismatch,

    /** The last allowed attempt was wrong, so the pairing is declined. */
    TooManyAttempts,
}

/** How many wrong codes a pairing allows before the phone declines it. */
const val MAX_PAIRING_ATTEMPTS = 5

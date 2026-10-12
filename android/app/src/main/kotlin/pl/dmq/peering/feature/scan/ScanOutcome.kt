package pl.dmq.peering.feature.scan

import pl.dmq.peering.wire.PairingPayload
import pl.dmq.peering.wire.PairingPayloadError

/** What the scanner does with a code it read: take it, or keep looking and say why it was not taken. */
enum class ScanOutcome {
    Used,

    /** Not a code this screen can use: not a device ID link, or not a pairing code at all. */
    NotAPairingCode,

    /** A pairing code, but not the six digits on this screen. */
    WrongCode,
}

/** A code scanned to find a Mac: used when it carries a device ID, parsed by the same rules as typed text. */
internal fun hostIdScanOutcome(text: String): ScanOutcome = try {
    PairingPayload.hostId(text)
    ScanOutcome.Used
} catch (refusal: PairingPayloadError) {
    ScanOutcome.NotAPairingCode
}

/** A code scanned while the six digits are compared: used when its code is the one on screen. */
internal fun pairingCodeScanOutcome(text: String, expectedCode: String): ScanOutcome {
    val scanned = PairingPayload.code(text) ?: return ScanOutcome.NotAPairingCode
    return if (scanned == expectedCode) ScanOutcome.Used else ScanOutcome.WrongCode
}

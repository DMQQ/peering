package pl.dmq.peering.feature.pairing

import pl.dmq.peering.wire.PairingPayload

internal const val PAIRING_CODE_LENGTH = 6

/** What the cells keep of whatever was typed or pasted: a pasted pairing link gives its code, anything else its first six digits. */
internal fun pairingDigits(input: String): String =
    PairingPayload.code(input) ?: input.filter { it in '0'..'9' }.take(PAIRING_CODE_LENGTH)

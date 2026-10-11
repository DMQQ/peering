package pl.dmq.peering.platform.identity

import java.math.BigInteger
import java.security.interfaces.ECPublicKey

private const val COORDINATE_SIZE = 32
private const val UNCOMPRESSED_PREFIX: Byte = 0x04
private const val MAX_NAME_LENGTH = 64
private const val FALLBACK_NAME = "Android device"
private val reservedNameCharacters = setOf(',', '+', '"', '\\', '<', '>', ';', '=')
private val whitespace = Regex("\\s+")

/** The 65-byte uncompressed P-256 point, 0x04 then X then Y, each coordinate left padded to 32 bytes. */
fun uncompressedPoint(ecPublicKey: ECPublicKey): ByteArray {
    val point = ecPublicKey.w
    val out = ByteArray(1 + 2 * COORDINATE_SIZE)
    out[0] = UNCOMPRESSED_PREFIX
    fixedWidth(point.affineX).copyInto(out, destinationOffset = 1)
    fixedWidth(point.affineY).copyInto(out, destinationOffset = 1 + COORDINATE_SIZE)
    return out
}

/** A display name that is safe inside an X.500 common name: no separators, single blanks, never empty. */
fun deviceName(raw: String?): String {
    val cleaned = raw.orEmpty()
        .filter { it !in reservedNameCharacters && !it.isISOControl() }
        .trim()
        .split(whitespace)
        .filter { it.isNotEmpty() }
        .joinToString(" ")
        .take(MAX_NAME_LENGTH)
        .trim()
    return cleaned.ifEmpty { FALLBACK_NAME }
}

private fun fixedWidth(value: BigInteger): ByteArray {
    require(value.signum() >= 0 && value.bitLength() <= COORDINATE_SIZE * Byte.SIZE_BITS) {
        "coordinate is outside the P-256 field"
    }
    val raw = value.toByteArray()
    val magnitude = if (raw.size > COORDINATE_SIZE) raw.copyOfRange(raw.size - COORDINATE_SIZE, raw.size) else raw
    return ByteArray(COORDINATE_SIZE).also { magnitude.copyInto(it, destinationOffset = COORDINATE_SIZE - magnitude.size) }
}

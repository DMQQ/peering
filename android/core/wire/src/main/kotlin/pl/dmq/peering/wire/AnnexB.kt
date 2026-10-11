package pl.dmq.peering.wire

class AnnexBException(message: String) : RuntimeException(message)

private val START_CODE = byteArrayOf(0, 0, 0, 1)
private const val LENGTH_SIZE = 4

/** Replaces each 4 byte big endian length in an AVCC access unit with a start code. The input is not changed. */
fun avccToAnnexB(avcc: ByteArray): ByteArray {
    val out = avcc.copyOf()
    var offset = 0
    while (offset < out.size) {
        if (out.size - offset < LENGTH_SIZE) throw AnnexBException("length prefix truncated at offset $offset")
        val length = readLength(out, offset)
        if (length > out.size - offset - LENGTH_SIZE) throw AnnexBException("NAL unit of $length bytes overruns the frame")
        START_CODE.copyInto(out, destinationOffset = offset)
        offset += LENGTH_SIZE + length.toInt()
    }
    return out
}

/** Each parameter set with a start code in front, as MediaCodec's csd buffers need. */
fun codecConfig(parameterSets: List<ByteArray>): List<ByteArray> = parameterSets.map { START_CODE + it }

/**
 * MediaCodec csd buffers for a stream's parameter sets. H.264 gives SPS then PPS as two buffers; HEVC gives VPS, SPS
 * and PPS in one buffer. [codec] is the wire name, "h264" or "hevc".
 */
fun csdFor(codec: String, parameterSets: List<ByteArray>): List<ByteArray> = when (codec) {
    "h264" -> {
        if (parameterSets.size != 2) throw AnnexBException("H.264 needs SPS and PPS, found ${parameterSets.size}")
        codecConfig(parameterSets)
    }
    "hevc" -> {
        if (parameterSets.size != 3) throw AnnexBException("HEVC needs VPS, SPS and PPS, found ${parameterSets.size}")
        listOf(codecConfig(parameterSets).reduce { all, part -> all + part })
    }
    else -> throw AnnexBException("no codec configuration for \"$codec\"")
}

private fun readLength(bytes: ByteArray, offset: Int): Long =
    ((bytes[offset].toLong() and 0xFF) shl 24) or
        ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
        ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
        (bytes[offset + 3].toLong() and 0xFF)

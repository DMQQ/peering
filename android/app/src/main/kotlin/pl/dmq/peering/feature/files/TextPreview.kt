package pl.dmq.peering.feature.files

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** Decodes a preview's bytes as UTF-8 lines. Null when the bytes are not valid UTF-8, since they cannot be shown as text. */
object TextPreview {
    fun lines(bytes: ByteArray): List<String>? {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val text = try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (error: java.nio.charset.CharacterCodingException) {
            return null
        }
        return text.split('\n').map { it.removeSuffix("\r") }.let { if (it.last().isEmpty()) it.dropLast(1) else it }
    }
}

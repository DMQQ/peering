package pl.dmq.peering.feature.scan

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrDecoderTest {
    private val text = "peering://pair?code=418205&secret=00ff"
    private val quietZoneModules = 4

    @Test
    fun readsTheTextOfAGeneratedQrCode() {
        val frame = luminanceOf(encode(text), scale = 4)

        assertEquals(text, QrDecoder.decode(frame.bytes, frame.width, frame.height))
    }

    @Test
    fun readsACodeInsideAFrameWithAnEmptyBorder() {
        val frame = luminanceOf(encode(text), scale = 3, padding = 60)

        assertEquals(text, QrDecoder.decode(frame.bytes, frame.width, frame.height))
    }

    @Test
    fun returnsNullWhenTheFrameHoldsNoCode() {
        val width = 200
        val height = 120
        val blank = ByteArray(width * height) { 0xF0.toByte() }

        assertNull(QrDecoder.decode(blank, width, height))
    }

    @Test
    fun compactRowsDropTheBytesBetweenRows() {
        val stride = 6
        val plane = ByteArray(stride * 2) { index -> (index % stride).toByte() }

        val compact = compactLuminanceRows(plane, rowStride = stride, width = 4, height = 2)

        assertEquals(listOf<Byte>(0, 1, 2, 3, 0, 1, 2, 3), compact.toList())
    }

    private fun encode(content: String): BitMatrix =
        QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.MARGIN to quietZoneModules))

    private class Frame(val bytes: ByteArray, val width: Int, val height: Int)

    private fun luminanceOf(matrix: BitMatrix, scale: Int, padding: Int = 0): Frame {
        val width = matrix.width * scale + padding * 2
        val height = matrix.height * scale + padding * 2
        val bytes = ByteArray(width * height) { index ->
            val x = index % width - padding
            val y = index / width - padding
            val dark = x >= 0 && y >= 0 && x < matrix.width * scale && y < matrix.height * scale &&
                matrix.get(x / scale, y / scale)
            if (dark) 0 else 0xFF.toByte()
        }
        return Frame(bytes, width, height)
    }
}

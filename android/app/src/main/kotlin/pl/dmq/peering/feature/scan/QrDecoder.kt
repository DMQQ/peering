package pl.dmq.peering.feature.scan

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer

/** Reads the first QR code in a luminance plane. Null when the frame holds none that reads. */
internal object QrDecoder {
    private val hints = mapOf<DecodeHintType, Any>(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
    )

    /** [luminance] holds [width] bytes per row, top row first; a reader is made per call, so calls may run on any thread. */
    fun decode(luminance: ByteArray, width: Int, height: Int): String? {
        require(width > 0 && height > 0 && luminance.size >= width * height) { "the luminance plane is smaller than its size" }
        val source = PlanarYUVLuminanceSource(luminance, width, height, 0, 0, width, height, false)
        val reader = MultiFormatReader().apply { setHints(hints) }
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (unreadable: ReaderException) {
            null
        }
    }
}

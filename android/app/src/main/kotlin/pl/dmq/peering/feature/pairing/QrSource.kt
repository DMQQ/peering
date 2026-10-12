package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.Flow

/** Text read from a QR code. The camera implementation is separate; this screen only takes the text. */
interface QrSource {
    fun scans(): Flow<String>
}

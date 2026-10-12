package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import pl.dmq.peering.feature.pairing.QrSource

/**
 * Until the camera scanner exists (AND-139), no code is ever scanned, and the host id can be typed instead. The flow stays
 * silent rather than inventing a scan.
 */
internal object NoCameraQrSource : QrSource {
    override fun scans(): Flow<String> = emptyFlow()
}

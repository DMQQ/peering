package pl.dmq.peering.feature.scan

/** What the scanner screen shows about the camera permission. */
sealed interface CameraPermissionState {
    data object Granted : CameraPermissionState

    /** Never asked: the screen asks straight away. */
    data object Unasked : CameraPermissionState

    /** Refused once, and the system will still ask: say why first, then ask again. */
    data object Rationale : CameraPermissionState

    /** Refused with no more prompts: only the system settings can grant it. */
    data object PermanentlyDenied : CameraPermissionState

    companion object {
        /**
         * Android reports "no rationale" both before the first request and after a permanent refusal, so [requested]
         * is what tells those two apart.
         */
        fun of(granted: Boolean, requested: Boolean, shouldShowRationale: Boolean): CameraPermissionState = when {
            granted -> Granted
            !requested -> Unasked
            shouldShowRationale -> Rationale
            else -> PermanentlyDenied
        }
    }
}

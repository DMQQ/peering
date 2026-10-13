package pl.dmq.peering.feature.scan

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraPermissionStateTest {
    @Test
    fun aGrantedPermissionShowsThePictureWhateverElseIsTrue() {
        assertEquals(CameraPermissionState.Granted, CameraPermissionState.of(granted = true, requested = false, shouldShowRationale = true))
    }

    @Test
    fun aPermissionNeverAskedIsAskedFor() {
        assertEquals(CameraPermissionState.Unasked, CameraPermissionState.of(granted = false, requested = false, shouldShowRationale = false))
    }

    @Test
    fun aRefusalWithRationaleLeftToAskAgainShowsTheReason() {
        assertEquals(CameraPermissionState.Rationale, CameraPermissionState.of(granted = false, requested = true, shouldShowRationale = true))
    }

    @Test
    fun aRefusalWithNoRationaleLeftIsPermanent() {
        assertEquals(CameraPermissionState.PermanentlyDenied, CameraPermissionState.of(granted = false, requested = true, shouldShowRationale = false))
    }
}

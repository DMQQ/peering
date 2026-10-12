package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenSecurityTest {
    @Test
    fun aWindowWithNoLockAndNoSessionStaysVisible() {
        assertFalse(ScreenSecurity.hidesContent(lockEnabled = false, lockShowing = false, sessionOnScreen = false))
    }

    @Test
    fun theLockAndASessionEachHideTheWindow() {
        assertTrue(ScreenSecurity.hidesContent(lockEnabled = true, lockShowing = false, sessionOnScreen = false))
        assertTrue(ScreenSecurity.hidesContent(lockEnabled = false, lockShowing = true, sessionOnScreen = false))
        assertTrue(ScreenSecurity.hidesContent(lockEnabled = false, lockShowing = false, sessionOnScreen = true))
    }

    @Test
    fun theLockLapsesOnlyWhenEnabledWithoutADeviceLock() {
        assertTrue(ScreenSecurity.lockLapsed(lockEnabled = true, deviceLockAvailable = false))
        assertFalse(ScreenSecurity.lockLapsed(lockEnabled = true, deviceLockAvailable = true))
        assertFalse(ScreenSecurity.lockLapsed(lockEnabled = false, deviceLockAvailable = false))
    }
}

package pl.dmq.peering.platform

import org.junit.Assert.assertEquals
import org.junit.Test

class PlatformInfoTest {
    @Test
    fun theClientPlatformIsAndroid() {
        assertEquals("android", CLIENT_PLATFORM)
    }
}

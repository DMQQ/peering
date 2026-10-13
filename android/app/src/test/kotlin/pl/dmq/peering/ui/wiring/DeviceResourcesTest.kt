package pl.dmq.peering.ui.wiring

import android.content.ComponentCallbacks2
import android.os.PowerManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceResourcesTest {
    @Test
    fun `battery saver or severe heat asks for the picture to be eased`() {
        assertTrue(DevicePower.savesPower(batterySaver = true, thermalStatus = PowerManager.THERMAL_STATUS_NONE))
        assertTrue(DevicePower.savesPower(batterySaver = false, thermalStatus = PowerManager.THERMAL_STATUS_SEVERE))
        assertTrue(DevicePower.savesPower(batterySaver = false, thermalStatus = PowerManager.THERMAL_STATUS_SHUTDOWN))
    }

    @Test
    fun `a warm phone or a full battery asks for nothing`() {
        assertFalse(DevicePower.savesPower(batterySaver = false, thermalStatus = PowerManager.THERMAL_STATUS_NONE))
        assertFalse(DevicePower.savesPower(batterySaver = false, thermalStatus = PowerManager.THERMAL_STATUS_MODERATE))
        assertEquals(PowerManager.THERMAL_STATUS_SEVERE, DevicePower.SEVERE_THERMAL_STATUS)
    }

    @Test
    fun `memory is trimmed when running low, when critical, and for every step after backgrounding`() {
        assertFalse(MemoryPressure.shouldTrim(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE))
        assertTrue(MemoryPressure.shouldTrim(ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW))
        assertTrue(MemoryPressure.shouldTrim(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL))
        assertFalse(MemoryPressure.shouldTrim(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN))
        assertTrue(MemoryPressure.shouldTrim(ComponentCallbacks2.TRIM_MEMORY_BACKGROUND))
        assertTrue(MemoryPressure.shouldTrim(ComponentCallbacks2.TRIM_MEMORY_COMPLETE))
    }
}

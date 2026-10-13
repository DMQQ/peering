package pl.dmq.peering.ui.wiring

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Whether the phone asks apps to use less power: its battery saver is on, or it has run hot. Followed for the life of the process. */
internal class DevicePower(context: Context) {
    private val power = context.getSystemService(PowerManager::class.java)
    private val state = MutableStateFlow(read())

    val saving: StateFlow<Boolean> = state.asStateFlow()

    init {
        ContextCompat.registerReceiver(
            context,
            object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) = refresh()
            },
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        power.addThermalStatusListener(ContextCompat.getMainExecutor(context)) { refresh() }
    }

    private fun refresh() {
        state.value = read()
    }

    private fun read(): Boolean = savesPower(power.isPowerSaveMode, power.currentThermalStatus)

    companion object {
        /** Severe heat is where the system starts throttling on its own; the phone eases the picture first. */
        const val SEVERE_THERMAL_STATUS = PowerManager.THERMAL_STATUS_SEVERE

        fun savesPower(batterySaver: Boolean, thermalStatus: Int): Boolean = batterySaver || thermalStatus >= SEVERE_THERMAL_STATUS
    }
}

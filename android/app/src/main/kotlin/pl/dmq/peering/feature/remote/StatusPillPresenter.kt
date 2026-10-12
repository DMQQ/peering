package pl.dmq.peering.feature.remote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Whether this session has already shown its pill. The remote screen is rebuilt when the user returns from the hub or
 * a panel, and it must not announce the same session again. The session's model holds one of these.
 */
class StatusPillMemory {
    var announced = false
}

/**
 * Whether the status pill is open. It opens by itself once when the session becomes ready and closes again after
 * [autoCloseMillis]; a tap toggles it and, opened that way, it stays until tapped. Touching a control inside it cancels
 * the automatic close. The state lives here rather than in a composable so a recomposition cannot reset it.
 */
class StatusPillPresenter(
    private val scope: CoroutineScope,
    private val autoCloseMillis: Long = AUTO_CLOSE_MILLIS,
    private val memory: StatusPillMemory = StatusPillMemory(),
) {
    var expanded by mutableStateOf(false)
        private set

    private var ready = false
    private var timer: Job? = null

    fun onReady(isReady: Boolean) {
        val becameReady = isReady && !ready
        ready = isReady
        if (!isReady) memory.announced = false
        if (!becameReady || memory.announced) return
        memory.announced = true
        expanded = true
        timer?.cancel()
        timer = scope.launch {
            delay(autoCloseMillis)
            expanded = false
        }
    }

    fun onTap() {
        timer?.cancel()
        expanded = !expanded
    }

    fun onInteraction() {
        timer?.cancel()
    }

    fun collapse() {
        timer?.cancel()
        expanded = false
    }

    companion object {
        const val AUTO_CLOSE_MILLIS = 2_500L
    }
}

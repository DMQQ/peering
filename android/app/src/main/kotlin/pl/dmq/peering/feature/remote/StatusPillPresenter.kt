package pl.dmq.peering.feature.remote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Whether the status pill is open. It opens by itself once when the session becomes ready and closes again after
 * [autoCloseMillis]; a tap toggles it and, opened that way, it stays until tapped. Touching a control inside it cancels
 * the automatic close. The state lives here rather than in a composable so a recomposition cannot reset it.
 */
class StatusPillPresenter(
    private val scope: CoroutineScope,
    private val autoCloseMillis: Long = AUTO_CLOSE_MILLIS,
) {
    var expanded by mutableStateOf(false)
        private set

    private var ready = false
    private var timer: Job? = null

    fun onReady(isReady: Boolean) {
        val becameReady = isReady && !ready
        ready = isReady
        if (!becameReady) return
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

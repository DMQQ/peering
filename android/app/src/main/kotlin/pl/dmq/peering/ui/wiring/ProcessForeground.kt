package pl.dmq.peering.ui.wiring

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * Whether any activity of the app is started. It is the process, not one activity: the hub and the main screen hand over
 * to each other without the app ever leaving the foreground, and the library delays the stop to bridge that handover.
 */
internal fun processForeground(): Flow<Boolean> = callbackFlow {
    val owner = ProcessLifecycleOwner.get()
    val observer = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            trySend(true)
        }

        override fun onStop(owner: LifecycleOwner) {
            trySend(false)
        }
    }
    trySend(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
    owner.lifecycle.addObserver(observer)
    awaitClose { owner.lifecycle.removeObserver(observer) }
}.distinctUntilChanged()

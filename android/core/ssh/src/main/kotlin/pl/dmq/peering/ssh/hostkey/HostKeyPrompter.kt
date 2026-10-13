package pl.dmq.peering.ssh.hostkey

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * First-sight questions waiting on the user, one on screen at a time. Several shells can ask at once; each question
 * belongs to the [owner] that asked, and closing that owner answers its questions with no.
 */
class HostKeyPrompter {
    private class Pending(val owner: String, val prompt: HostKeyPrompt, val answer: CompletableDeferred<Boolean>)

    private val queue = ArrayDeque<Pending>()
    private val mutableCurrent = MutableStateFlow<HostKeyPrompt?>(null)

    /** The question on screen, or null. */
    val current: StateFlow<HostKeyPrompt?> = mutableCurrent.asStateFlow()

    /** Suspends until the user answers or the owner is refused. */
    suspend fun ask(prompt: HostKeyPrompt, owner: String): Boolean {
        val pending = Pending(owner, prompt, CompletableDeferred())
        synchronized(queue) {
            queue.addLast(pending)
            publish()
        }
        try {
            return pending.answer.await()
        } finally {
            synchronized(queue) {
                if (queue.remove(pending)) publish()
            }
        }
    }

    fun answer(accepted: Boolean) {
        val head = synchronized(queue) { queue.firstOrNull() } ?: return
        head.answer.complete(accepted)
        synchronized(queue) {
            queue.remove(head)
            publish()
        }
    }

    fun refuse(owner: String) {
        val owned = synchronized(queue) {
            queue.filter { it.owner == owner }.also { queue.removeAll(it.toSet()); publish() }
        }
        owned.forEach { it.answer.complete(false) }
    }

    fun refuseAll() {
        val all = synchronized(queue) { queue.toList().also { queue.clear(); publish() } }
        all.forEach { it.answer.complete(false) }
    }

    private fun publish() {
        mutableCurrent.value = queue.firstOrNull()?.prompt
    }
}

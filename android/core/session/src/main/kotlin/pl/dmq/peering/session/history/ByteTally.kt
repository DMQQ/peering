package pl.dmq.peering.session.history

import java.util.concurrent.atomic.AtomicLong

/** Bytes moved over one session's connections, summed across the control stream, the picture lane and datagrams. Readers and writers run on different threads, so each figure is atomic. */
class ByteTally {
    private val receivedBytes = AtomicLong()
    private val sentBytes = AtomicLong()

    val received: Long get() = receivedBytes.get()
    val sent: Long get() = sentBytes.get()

    fun addReceived(count: Int) {
        receivedBytes.addAndGet(count.toLong())
    }

    fun addSent(count: Int) {
        sentBytes.addAndGet(count.toLong())
    }
}

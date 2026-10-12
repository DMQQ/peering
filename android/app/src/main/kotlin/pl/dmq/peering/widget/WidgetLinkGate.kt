package pl.dmq.peering.widget

/** What a widget tap puts in its intent: the `peering://` address and the install's nonce. */
data class LinkRequest(val data: String, val nonce: String?)

/**
 * Decides what the exported main activity does with a link: only a request carrying the install's nonce counts, and one
 * that arrives while the app lock shows waits for the unlock.
 */
class WidgetLinkGate(private val expectedNonce: String, private val queue: LockedLinkQueue = LockedLinkQueue()) {
    /** The link to act on now, or null when the request is forged, unreadable, or held until [released]. */
    fun receive(request: LinkRequest, locked: Boolean): WidgetLink? {
        if (!LinkNonce.accepts(expectedNonce, request.nonce)) return null
        val link = WidgetLink.parse(request.data) ?: return null
        return queue.admit(link, locked)
    }

    /** The link held while the lock showed, handed out once. */
    fun released(): WidgetLink? = queue.release()

    companion object {
        fun requestFor(link: String, nonce: String): LinkRequest = LinkRequest(link, nonce)
    }
}

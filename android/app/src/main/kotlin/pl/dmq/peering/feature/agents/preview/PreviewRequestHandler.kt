package pl.dmq.peering.feature.agents.preview

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.flow.produceIn
import kotlinx.coroutines.runBlocking
import pl.dmq.peering.session.preview.PreviewAddress
import pl.dmq.peering.session.preview.PreviewPolicy
import pl.dmq.peering.session.preview.PreviewRedirect
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewProxyEvent

/**
 * Answers the web view's requests for pages on the computer's loopback by asking the computer to fetch them. A request
 * for anything on the phone's own loopback is never left to the web view, which would dial the phone itself.
 * [onPageFailure] is told when the page itself, not one of its files, could not be had, so the screen can say why.
 * Runs on the web view's loading threads and blocks them while waiting for the computer.
 */
class PreviewRequestHandler(
    private val fetch: PreviewFetch,
    private val scope: CoroutineScope,
    private val onPageFailure: (PreviewFailure) -> Unit,
) {
    /** Null where the request is not for the loopback, so the web view loads it as it would anyway. */
    fun handle(url: String, method: String, headers: Map<String, String>, isMainFrame: Boolean): PreviewReply? {
        var address = PreviewAddress.fromUrl(url)
        if (address == null) {
            return if (PreviewAddress.namesLoopback(url)) refuse(isMainFrame, PreviewFailure.NOT_ALLOWED) else null
        }
        val verb = method.uppercase()
        if (verb !in PreviewPolicy.carriedMethods) return PreviewReply.text(PreviewReply.NOT_IMPLEMENTED, "Preview: requests that send data are not carried")
        val sent = PreviewPolicy.filteredRequestHeaders(headers.filterKeys { !it.equals("if-none-match", true) && !it.equals("if-modified-since", true) })
        repeat(MAX_REDIRECTS + 1) {
            val events = fetch(address!!.port, verb, address!!.target, sent).produceIn(scope)
            when (val head = firstEvent(events)) {
                is PreviewProxyEvent.Head -> {
                    val location = head.headers.firstOrNull { it.name.equals("location", ignoreCase = true) }?.value
                    when (val redirect = PreviewRedirect.of(head.status, location, address!!)) {
                        PreviewRedirect.NotARedirect -> return PreviewReply.from(head.status, head.headers, PreviewBodyStream(events))
                        PreviewRedirect.Refuse -> {
                            events.cancel()
                            return refuse(isMainFrame, PreviewFailure.NOT_ALLOWED)
                        }
                        is PreviewRedirect.Follow -> {
                            events.cancel()
                            if (isMainFrame) return PreviewReply.redirectPage(redirect.address.url)
                            address = redirect.address
                        }
                    }
                }
                is PreviewProxyEvent.Failure -> return refuse(isMainFrame, head.reason)
                else -> return refuse(isMainFrame, PreviewFailure.DISCONNECTED)
            }
        }
        return refuse(isMainFrame, PreviewFailure.FAILED)
    }

    private fun firstEvent(events: ReceiveChannel<PreviewProxyEvent>): PreviewProxyEvent? =
        runBlocking { events.receiveCatching().getOrNull() }

    private fun refuse(isMainFrame: Boolean, reason: PreviewFailure): PreviewReply {
        if (isMainFrame) onPageFailure(reason)
        return PreviewReply.failure(reason)
    }

    private companion object {
        const val MAX_REDIRECTS = 5
    }
}

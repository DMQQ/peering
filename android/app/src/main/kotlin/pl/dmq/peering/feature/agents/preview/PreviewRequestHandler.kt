package pl.dmq.peering.feature.agents.preview

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.flow.produceIn
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.preview.PreviewAddress
import pl.dmq.peering.session.preview.PreviewPolicy
import pl.dmq.peering.session.preview.PreviewRedirect
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewProxyEvent

/**
 * Answers the web view's requests for pages on the computer's loopback by asking the computer to fetch them. A request
 * for anything on the phone's own loopback is never left to the web view, which would dial the phone itself.
 * [onPageFailure] is told when the page itself, not one of its files, could not be had, so the screen can say why.
 * Runs on the web view's loading threads and blocks them while waiting for the computer, for at most
 * [firstByteTimeoutMillis] before the reply starts and [chunkTimeoutMillis] between pieces of its body.
 * Any http or https request that is not for the loopback is refused rather than left to the phone's network.
 */
class PreviewRequestHandler(
    private val fetch: PreviewFetch,
    private val scope: CoroutineScope,
    private val texts: PreviewTexts,
    private val firstByteTimeoutMillis: Long = FIRST_BYTE_TIMEOUT_MILLIS,
    private val chunkTimeoutMillis: Long = CHUNK_TIMEOUT_MILLIS,
    private val onPageFailure: (PreviewFailure) -> Unit,
) {
    /** Null for a scheme that cannot leave the web view, such as about: or data:. */
    fun handle(url: String, method: String, headers: Map<String, String>, isMainFrame: Boolean): PreviewReply? {
        val first = PreviewAddress.fromUrl(url)
        if (first == null) {
            val onTheNetwork = url.startsWith("http://", ignoreCase = true) || url.startsWith("https://", ignoreCase = true)
            return if (onTheNetwork || PreviewAddress.namesLoopback(url)) failureReply(isMainFrame, PreviewFailure.NOT_ALLOWED) else null
        }
        var current: PreviewAddress = first
        val verb = method.uppercase()
        if (verb !in PreviewPolicy.carriedMethods) return PreviewReply.text(PreviewReply.NOT_IMPLEMENTED, texts.dataNotCarried())
        val sent = PreviewPolicy.filteredRequestHeaders(headers.filterKeys { !it.equals("if-none-match", true) && !it.equals("if-modified-since", true) })
        repeat(MAX_REDIRECTS + 1) {
            val events = fetch(current.port, verb, current.target, sent).produceIn(scope)
            when (val head = firstEvent(events)) {
                is PreviewProxyEvent.Head -> {
                    val location = head.headers.firstOrNull { it.name.equals("location", ignoreCase = true) }?.value
                    when (val redirect = PreviewRedirect.of(head.status, location, current)) {
                        PreviewRedirect.NotARedirect -> return PreviewReply.from(head.status, head.headers, PreviewBodyStream(events, chunkTimeoutMillis))
                        PreviewRedirect.Refuse -> {
                            events.cancel()
                            return failureReply(isMainFrame, PreviewFailure.NOT_ALLOWED)
                        }
                        is PreviewRedirect.Follow -> {
                            events.cancel()
                            if (isMainFrame) return PreviewReply.redirectPage(redirect.address.url)
                            current = redirect.address
                        }
                    }
                }
                is PreviewProxyEvent.Failure -> return failureReply(isMainFrame, head.reason)
                else -> {
                    events.cancel()
                    return failureReply(isMainFrame, PreviewFailure.DISCONNECTED)
                }
            }
        }
        return failureReply(isMainFrame, PreviewFailure.FAILED)
    }

    private fun firstEvent(events: ReceiveChannel<PreviewProxyEvent>): PreviewProxyEvent? =
        runBlocking { withTimeoutOrNull(firstByteTimeoutMillis) { events.receiveCatching().getOrNull() } }

    private fun failureReply(isMainFrame: Boolean, reason: PreviewFailure): PreviewReply {
        if (isMainFrame) onPageFailure(reason)
        return PreviewReply.failure(reason, texts)
    }

    private companion object {
        const val MAX_REDIRECTS = 5
        const val FIRST_BYTE_TIMEOUT_MILLIS = 15_000L
        const val CHUNK_TIMEOUT_MILLIS = 30_000L
    }
}

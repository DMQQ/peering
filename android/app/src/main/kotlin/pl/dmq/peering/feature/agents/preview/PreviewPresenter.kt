package pl.dmq.peering.feature.agents.preview

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.session.preview.PreviewAddress
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewHeader
import pl.dmq.peering.wire.PreviewProxyEvent

enum class PreviewPhase { IDLE, LOADING, LOADED, FAILED }

/** A sentence the screen shows under the address field; kept as a case so the words live in resources. */
enum class PreviewNotice { ONLY_LOOPBACK, LINKS_OUTSIDE }

data class PreviewUi(
    val phase: PreviewPhase = PreviewPhase.IDLE,
    val failure: PreviewFailure? = null,
    /** What the address field shows for the page on screen. */
    val address: String = "",
    val notice: PreviewNotice? = null,
    val canGoBack: Boolean = false,
    val detectedPorts: List<Int> = emptyList(),
    val probing: Boolean = false,
)

sealed interface NavigationDecision {
    data object Allow : NavigationDecision

    data object Block : NavigationDecision
}

/** Starts a fetch of one URL on the computer's loopback. */
typealias PreviewFetch = (port: Int, method: String, target: String, headers: List<PreviewHeader>) -> Flow<PreviewProxyEvent>

/** The proxy client as the preview screens use it. */
fun previewFetchOf(client: PreviewProxyClient): PreviewFetch = { port, method, target, headers ->
    client.fetch(port, method, target, headers)
}

/**
 * The web preview's state: which page is open, whether it loaded, and which servers answer on the computer. The web view
 * itself is the screen's; it reports here and asks here whether a navigation may go ahead.
 */
class PreviewPresenter(private val fetch: PreviewFetch, private val scope: CoroutineScope) {
    private val state = MutableStateFlow(PreviewUi())
    private var pageFailure: PreviewFailure? = null

    val ui: StateFlow<PreviewUi> = state.asStateFlow()

    /** The address to load for what was typed, or null, with a notice, when it names anything but a loopback port. */
    fun open(typed: String): PreviewAddress? {
        val address = PreviewAddress.fromTyped(typed)
        state.update { it.copy(notice = if (address == null) PreviewNotice.ONLY_LOOPBACK else null) }
        return address
    }

    fun navigation(url: String): NavigationDecision {
        if (url == ABOUT_BLANK || PreviewAddress.fromUrl(url) != null) return NavigationDecision.Allow
        state.update { it.copy(notice = PreviewNotice.LINKS_OUTSIDE) }
        return NavigationDecision.Block
    }

    fun pageStarted() {
        pageFailure = null
        state.update { it.copy(phase = PreviewPhase.LOADING, failure = null, notice = null) }
    }

    /** The page itself, not one of its files, could not be had. */
    fun pageFailed(reason: PreviewFailure) {
        if (pageFailure == null) pageFailure = reason
    }

    fun pageFinished(url: String?, canGoBack: Boolean) {
        val failure = pageFailure
        state.update {
            it.copy(
                phase = if (failure == null) PreviewPhase.LOADED else PreviewPhase.FAILED,
                failure = failure,
                canGoBack = canGoBack,
                address = url?.let(PreviewAddress::fromUrl)?.display ?: it.address,
            )
        }
    }

    /** Looks for the usual dev-server ports with something listening. */
    fun detect() {
        if (state.value.probing) return
        state.update { it.copy(probing = true) }
        scope.launch {
            val found = PreviewPortProbe.listening(fetch)
            state.update { it.copy(detectedPorts = found, probing = false) }
        }
    }

    fun showStart() = state.update { it.copy(phase = PreviewPhase.IDLE, failure = null, address = "", canGoBack = false) }

    private companion object {
        const val ABOUT_BLANK = "about:blank"
    }
}

/** Finds which of the usual dev-server ports have something listening, by asking the proxy for `HEAD /` on each. */
object PreviewPortProbe {
    val commonPorts: List<Int> = listOf(3000, 3001, 4173, 5173, 8000, 8080)

    suspend fun listening(fetch: PreviewFetch): List<Int> = coroutineScope {
        commonPorts
            .map { port -> async { port to (fetch(port, "HEAD", "/", emptyList()).firstOrNull() is PreviewProxyEvent.Head) } }
            .awaitAll()
            .filter { (_, answering) -> answering }
            .map { (port, _) -> port }
    }
}

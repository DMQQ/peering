package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.preview.NavigationDecision
import pl.dmq.peering.feature.agents.preview.PreviewFetch
import pl.dmq.peering.feature.agents.preview.PreviewNotice
import pl.dmq.peering.feature.agents.preview.PreviewPhase
import pl.dmq.peering.feature.agents.preview.PreviewPresenter
import pl.dmq.peering.session.preview.PreviewAddress
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewProxyEvent

class PreviewPresenterTest {
    private val listening = mutableSetOf(3000, 5173)
    private val fetch: PreviewFetch = { port, _, _, _ ->
        if (port in listening) flowOf(PreviewProxyEvent.Head(1, 200), PreviewProxyEvent.End(1))
        else flowOf(PreviewProxyEvent.Failure(1, PreviewFailure.NOT_LISTENING))
    }
    private val presenter = PreviewPresenter(fetch, CoroutineScope(UnconfinedTestDispatcher()))

    @Test
    fun theUsualPortsAreProbedAndOnlyTheAnsweringOnesAreListed() {
        presenter.detect()
        assertEquals(listOf(3000, 5173), presenter.ui.value.detectedPorts)
        assertFalse(presenter.ui.value.probing)
    }

    @Test
    fun aTypedLoopbackAddressIsOpenedAndAnythingElseSaysWhy() {
        assertEquals(PreviewAddress(3000, "/"), presenter.open("3000"))
        assertNull(presenter.ui.value.notice)
        assertNull(presenter.open("example.com:80"))
        assertEquals(PreviewNotice.ONLY_LOOPBACK, presenter.ui.value.notice)
    }

    @Test
    fun aLoadedPageShowsItsLoopbackAddress() {
        presenter.pageStarted()
        assertEquals(PreviewPhase.LOADING, presenter.ui.value.phase)
        presenter.pageFinished("http://localhost:3000/docs?a=1", canGoBack = true)
        val ui = presenter.ui.value
        assertEquals(PreviewPhase.LOADED, ui.phase)
        assertEquals("localhost:3000/docs?a=1", ui.address)
        assertTrue(ui.canGoBack)
    }

    @Test
    fun aPageThatCouldNotBeHadEndsFailedWithTheReason() {
        presenter.pageStarted()
        presenter.pageFailed(PreviewFailure.NOT_LISTENING)
        presenter.pageFinished("http://localhost:3000/", canGoBack = false)
        assertEquals(PreviewPhase.FAILED, presenter.ui.value.phase)
        assertEquals(PreviewFailure.NOT_LISTENING, presenter.ui.value.failure)
        presenter.pageStarted()
        presenter.pageFinished("http://localhost:3000/", canGoBack = false)
        assertEquals(PreviewPhase.LOADED, presenter.ui.value.phase)
        assertNull(presenter.ui.value.failure)
    }

    @Test
    fun linksOutsideTheLoopbackAreBlockedWithANotice() {
        assertEquals(NavigationDecision.Allow, presenter.navigation("http://localhost:3000/next"))
        assertEquals(NavigationDecision.Allow, presenter.navigation("about:blank"))
        assertEquals(NavigationDecision.Block, presenter.navigation("https://example.com/"))
        assertEquals(PreviewNotice.LINKS_OUTSIDE, presenter.ui.value.notice)
        assertEquals(NavigationDecision.Block, presenter.navigation("http://localhost:51515/"))
        assertEquals(NavigationDecision.Block, presenter.navigation("intent://x#Intent;end"))
    }

    @Test
    fun backToTheStartForgetsThePageButKeepsTheDetectedServers() {
        presenter.detect()
        presenter.pageStarted()
        presenter.pageFinished("http://localhost:3000/", canGoBack = true)
        presenter.showStart()
        val ui = presenter.ui.value
        assertEquals(PreviewPhase.IDLE, ui.phase)
        assertEquals("", ui.address)
        assertEquals(listOf(3000, 5173), ui.detectedPorts)
    }
}

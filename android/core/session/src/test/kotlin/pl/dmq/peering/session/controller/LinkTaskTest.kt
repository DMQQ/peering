package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LinkTaskTest {
    @Test
    fun aTaskThatThrowsEndsTheLinkAndIsNotedByItsTypeOnly() = runTest {
        val ended = CompletableDeferred<LinkEnd>()
        val notes = mutableListOf<String>()

        coroutineScope {
            launchLinkTask(ended, notes::add) { throw IllegalStateException("10.0.0.7 refused") }
        }

        assertEquals(LinkEnd.Lost, ended.await())
        assertEquals(listOf("a link task failed with IllegalStateException"), notes)
    }

    @Test
    fun aTaskThatReturnsEndsTheLinkWithoutANote() = runTest {
        val ended = CompletableDeferred<LinkEnd>()
        val notes = mutableListOf<String>()

        coroutineScope { launchLinkTask(ended, notes::add) { } }

        assertEquals(LinkEnd.Lost, ended.await())
        assertEquals(emptyList<String>(), notes)
    }
}

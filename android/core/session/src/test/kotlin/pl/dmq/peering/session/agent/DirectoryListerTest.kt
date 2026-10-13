package pl.dmq.peering.session.agent

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.RemoteDirectoryEntry

class DirectoryListerTest {
    private val asked = mutableListOf<String>()
    private var clock = 0L

    private fun TestScope.lister() = DirectoryLister({ asked += it }, this, { clock })

    private fun answer(vararg names: String) =
        AgentEvent.Directory("/ignored", names.map { RemoteDirectoryEntry(it, false, false, 0, "rw-") }, truncated = false)

    @Test
    fun `folders are asked for one at a time and the next goes out when the answer arrives`() = runTest {
        val lister = lister()

        lister.request("/a")
        lister.request("/b")
        assertEquals(listOf("/a"), asked)

        lister.onEvent(answer("x.md"))
        assertEquals(listOf("/a", "/b"), asked)
        assertEquals(listOf("x.md"), lister.listings.value.getValue("/a").entries!!.map { it.name })
        lister.onEvent(AgentEvent.BrowseFailure("/b", "denied"))
        assertEquals("denied", lister.listings.value.getValue("/b").failure)
        assertNull(lister.listings.value.getValue("/b").entries)
    }

    @Test
    fun `a recent answer is kept and an old one is asked for again`() = runTest {
        val lister = lister()
        lister.request("/a")
        lister.onEvent(answer())

        clock = 30_000
        lister.request("/a")
        assertEquals(listOf("/a"), asked)

        clock = 61_000
        lister.request("/a")
        assertEquals(listOf("/a", "/a"), asked)
    }

    @Test
    fun `the same folder is not asked for twice while it is out or queued`() = runTest {
        val lister = lister()

        lister.request("/a")
        lister.request("/a")
        lister.request("/b")
        lister.request("/b")
        lister.onEvent(answer())
        lister.onEvent(answer())

        assertEquals(listOf("/a", "/b"), asked)
    }

    @Test
    fun `a folder the computer never answers is given up on and the queue moves on`() = runTest {
        val lister = lister()
        lister.request("/a")
        lister.request("/b")

        advanceTimeBy(8_001)
        runCurrent()

        assertEquals(listOf("/a", "/b"), asked)
        assertTrue(lister.listings.value.getValue("/a").entries!!.isEmpty())
    }

    @Test
    fun `an answer with nothing asked is ignored`() = runTest {
        val lister = lister()

        lister.onEvent(answer("stray"))

        assertTrue(lister.listings.value.isEmpty())
    }
}

package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class WidgetLimitsTest {
    @Test
    fun computersAndNamesAreCapped() {
        val computers = (1..200).map { KnownComputer("id$it", "n".repeat(500)) }

        val bounded = WidgetLimits.bounded(QuickConnectSnapshot(computers))

        assertEquals(WidgetLimits.MAX_COMPUTERS, bounded.computers.size)
        assertEquals(WidgetLimits.MAX_TEXT, bounded.computers.first().name.length)
    }

    @Test
    fun aConnectedIdOutsideTheKeptComputersIsDropped() {
        val computers = (1..200).map { KnownComputer("id$it", "n") }

        val bounded = WidgetLimits.bounded(QuickConnectSnapshot(computers, connectedId = "id200", onlineIds = setOf("id1", "id200")))

        assertNull(bounded.connectedId)
        assertEquals(setOf("id1"), bounded.onlineIds)
    }

    @Test
    fun mergedChatsAreCapped() {
        val book = AgentSnapshotBook()
        book.update("h", (1..100).map { AgentChatEntry("c$it", "h", "t", "f", AgentChatTone.FINISHED, it.toLong()) })

        assertEquals(WidgetLimits.MAX_CHATS, book.merged().size)
    }

    @Test
    fun chatTitlesAreCapped() {
        val entries = AgentChatEntries.from(
            "h",
            listOf(
                AgentChatSession(
                    info = AgentSessionInfo(
                        id = "S", agentID = "claude", title = "t".repeat(1000), directory = "/a/b/",
                        state = AgentSessionState.IDLE, lastIndex = 0, createdAt = 0.0,
                    ),
                ),
            ),
            nowSeconds = 0,
        )

        assertEquals(WidgetLimits.MAX_TEXT, entries.single().title.length)
    }
}

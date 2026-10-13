package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetCodecTest {
    @Test
    fun quickConnectSnapshotSurvivesARoundTrip() {
        val snapshot = QuickConnectSnapshot(
            computers = listOf(KnownComputer("a", "Desk \"main\""), KnownComputer("b", "Lapótop")),
            connectedId = "b",
            onlineIds = setOf("a", "b"),
        )
        assertEquals(snapshot, WidgetCodec.decodeQuickConnect(WidgetCodec.encode(snapshot)))
    }

    @Test
    fun agentsSnapshotSurvivesARoundTrip() {
        val snapshot = AgentsSnapshot(
            chats = listOf(
                AgentChatEntry("c1", "h1", "Fix build", "app", AgentChatTone.NEEDS_YOU, 100),
                AgentChatEntry("c2", null, "Docs", "site", AgentChatTone.FINISHED, 50),
            ),
            publishedAtSeconds = 200,
        )
        assertEquals(snapshot, WidgetCodec.decodeAgents(WidgetCodec.encode(snapshot)))
    }

    @Test
    fun missingOrCorruptTextReadsAsEmpty() {
        assertEquals(QuickConnectSnapshot(), WidgetCodec.decodeQuickConnect(null))
        assertEquals(QuickConnectSnapshot(), WidgetCodec.decodeQuickConnect("{not json"))
        assertEquals(AgentsSnapshot(), WidgetCodec.decodeAgents("[1,2]"))
        assertEquals(AgentsSnapshot(), WidgetCodec.decodeAgents(""))
    }

    @Test
    fun anEntryWithAnUnknownToneOrNoIdIsSkipped() {
        val text = """{"publishedAt":5,"chats":[{"id":"x","tone":"SLEEPING"},{"title":"no id","tone":"WORKING"},{"id":"ok","tone":"WORKING"}]}"""
        val chats = WidgetCodec.decodeAgents(text).chats
        assertEquals(listOf("ok"), chats.map { it.id })
    }

    @Test
    fun anOlderSnapshotWithoutNewFieldsStillReads() {
        val decoded = WidgetCodec.decodeQuickConnect("""{"computers":[{"id":"a"}]}""")
        assertEquals(listOf(KnownComputer("a", "")), decoded.computers)
        assertEquals(null, decoded.connectedId)
    }
}

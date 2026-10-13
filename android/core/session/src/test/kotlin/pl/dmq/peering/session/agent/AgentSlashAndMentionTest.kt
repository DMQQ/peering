package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.RemoteDirectoryEntry

class AgentSlashAndMentionTest {
    private fun entry(name: String, directory: Boolean = false) = RemoteDirectoryEntry(name, directory, false, 0, "rw-")

    private fun slash(typed: String, agent: String = "claude", listing: (String) -> List<RemoteDirectoryEntry>? = { null }) =
        AgentSlash.suggestions(typed, agent, "/Users/me/app", offersUsage = true, offersModel = true, listing = listing)

    @Test
    fun `a slash query is the first word only while the draft is one word`() {
        assertEquals("", AgentSlash.query("/"))
        assertEquals("comp", AgentSlash.query("/comp"))
        assertNull(AgentSlash.query("/compact now"))
        assertNull(AgentSlash.query("hello /x"))
    }

    @Test
    fun `claude looks in the project and the home folder, the project first`() {
        assertEquals(
            listOf(
                "/Users/me/app/.claude/commands", "/Users/me/app/.claude/skills",
                "/Users/me/.claude/commands", "/Users/me/.claude/skills",
            ),
            AgentSlash.folders("/Users/me/app/", "claude"),
        )
        assertEquals(emptyList<String>(), AgentSlash.folders("/Users/me/app", "codex"))
    }

    @Test
    fun `the app's own commands come first and a host without usage or model leaves them out`() {
        assertEquals(listOf("model", "rename", "usage", "clear", "compact"), slash("").map { it.name })
        val bare = AgentSlash.suggestions("", "codex", "/p", offersUsage = false, offersModel = false) { null }
        assertEquals(listOf("rename"), bare.map { it.name })
    }

    @Test
    fun `commands and skills are read off the folders, with their scope`() {
        val found = slash("") { folder ->
            when (folder) {
                "/Users/me/app/.claude/commands" -> listOf(entry("deploy.md"), entry("notes.txt"), entry(".hidden.md"))
                "/Users/me/.claude/skills" -> listOf(entry("review", directory = true), entry("loose.md"))
                else -> null
            }
        }

        val deploy = found.single { it.name == "deploy" }
        assertEquals(SlashKind.COMMAND, deploy.kind)
        assertEquals(SlashDetail.THIS_PROJECT, deploy.detail)
        val review = found.single { it.name == "review" }
        assertEquals(SlashKind.SKILL, review.kind)
        assertEquals(SlashDetail.YOURS, review.detail)
        assertNull(found.firstOrNull { it.name == "notes" || it.name == "loose" || it.name.startsWith(".") })
    }

    @Test
    fun `the project wins a name both folders define`() {
        val found = slash("") { folder ->
            when (folder) {
                "/Users/me/app/.claude/commands" -> listOf(entry("ship.md"))
                "/Users/me/.claude/commands" -> listOf(entry("ship.md"))
                else -> null
            }
        }

        assertEquals(SlashDetail.THIS_PROJECT, found.single { it.name == "ship" }.detail)
    }

    @Test
    fun `typing narrows by name and puts names that start with it first`() {
        val found = slash("re") { folder -> if (folder.endsWith("commands")) listOf(entry("prepare.md"), entry("redo.md")) else null }

        assertEquals(listOf("rename", "redo", "prepare"), found.map { it.name })
    }

    @Test
    fun `a mention is the last word when it starts with an at sign`() {
        assertNull(MentionQuery.of("hello"))
        assertNull(MentionQuery.of("a@b"))
        assertNull(MentionQuery.of("@done "))
        val query = MentionQuery.of("look at @src/ma")!!
        assertEquals("src/", query.folderPart)
        assertEquals("ma", query.namePart)
        assertEquals("", MentionQuery.of("@")!!.namePart)
    }

    @Test
    fun `the folder to list is relative to the project unless absolute, with dots resolved`() {
        assertEquals("/Users/me/app/src", MentionQuery.of("@src/")!!.folder("/Users/me/app/"))
        assertEquals("/Users/me/app", MentionQuery.of("@x")!!.folder("/Users/me/app"))
        assertEquals("/Users/me/other", MentionQuery.of("@../other/")!!.folder("/Users/me/app"))
        assertEquals("/etc", MentionQuery.of("@/etc/h")!!.folder("/Users/me/app"))
    }

    @Test
    fun `matches hide dot files unless a dot is typed and list folders before files`() {
        val entries = listOf(entry("main.kt"), entry(".git", directory = true), entry("main", directory = true), entry("domain.kt"))

        assertEquals(listOf("main", "main.kt", "domain.kt"), MentionQuery.of("@ma")!!.matches(entries).map { it.name })
        assertEquals(listOf("main", "domain.kt", "main.kt"), MentionQuery.of("@")!!.matches(entries).map { it.name })
        assertEquals(listOf(".git", "domain.kt", "main.kt"), MentionQuery.of("@.")!!.matches(entries).map { it.name })
        assertEquals(emptyList<RemoteDirectoryEntry>(), MentionQuery.of("@")!!.matches(null))
    }

    @Test
    fun `picking a folder keeps the mention open and a file ends it, escaping spaces`() {
        val query = MentionQuery.of("see @sr")!!

        assertEquals("see @src/", query.replacing("see @sr", "src", isFolder = true))
        assertEquals("see @my\\ file.md ", query.replacing("see @sr", "my file.md", isFolder = false))
    }
}

package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.attach.AttachmentOutcome
import pl.dmq.peering.feature.agents.attach.AttachmentSender
import pl.dmq.peering.feature.agents.attach.AttachmentSource
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.files.UploadFailure
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class ComposerAttachTest {
    private class HeldSender : AttachmentSender {
        val folders = mutableListOf<String>()
        private var pending = CompletableDeferred<AttachmentOutcome>()
        var name = "notes.pdf"

        override suspend fun send(source: AttachmentSource, folder: String, onNamed: (String) -> Unit): AttachmentOutcome {
            folders += folder
            onNamed(name)
            return pending.await()
        }

        fun finish(outcome: AttachmentOutcome) {
            pending.complete(outcome)
            pending = CompletableDeferred()
        }
    }

    private fun session(id: String, directory: String, state: AgentSessionState = AgentSessionState.IDLE) = AgentChatSession(
        info = AgentSessionInfo(id, "claude", "t", directory, state, 0L, createdAt = 0.0),
    )

    private class Harness(chats: AgentChatState, val sender: HeldSender?) {
        val port = FakeAgentsPort(chats)
        val presenter = ComposerPresenter(
            port, FakeComposerDraftStore(), port.chats, modelPickerSupported = false,
            scope = CoroutineScope(UnconfinedTestDispatcher()), attachments = sender,
        )
    }

    private fun harness(state: AgentSessionState = AgentSessionState.IDLE, sender: HeldSender? = HeldSender()) =
        Harness(AgentChatState(listOf(session("A", "/work/app", state)), "A"), sender)

    private val doc = AttachmentSource.Document("content://doc/1")

    @Test
    fun aFileGoesToTheChatsFolderAndItsPathJoinsTheDraft() {
        val h = harness()
        h.presenter.attach(doc)
        assertEquals(listOf("/work/app"), h.sender!!.folders)
        assertEquals("notes.pdf", h.presenter.ui.value.uploadingName)
        h.sender.finish(AttachmentOutcome.Sent("notes.pdf", "/work/app/notes.pdf"))
        val ui = h.presenter.ui.value
        assertNull(ui.uploadingName)
        assertEquals(listOf("/work/app/notes.pdf"), ui.attachedPaths)
        assertEquals(listOf("notes.pdf"), ui.attachments.map { it.name })
    }

    @Test
    fun sendingIsHeldWhileAFileIsOnItsWay() {
        val h = harness()
        h.presenter.onTextChanged("look at this")
        h.presenter.attach(doc)
        assertFalse(h.presenter.ui.value.actionEnabled)
        h.presenter.send()
        assertTrue(h.port.calls.none { it.startsWith("prompt") })
        h.sender!!.finish(AttachmentOutcome.Sent("notes.pdf", "/work/app/notes.pdf"))
        h.presenter.send()
        assertEquals(listOf("prompt:A:@/work/app/notes.pdf look at this"), h.port.calls)
    }

    @Test
    fun aSecondFileWaitsForTheFirst() {
        val h = harness()
        h.presenter.attach(doc)
        h.presenter.attach(AttachmentSource.Photo("content://photo/2"))
        assertEquals(1, h.sender!!.folders.size)
    }

    @Test
    fun aFileThatDidNotArriveIsShownFailedAndLeftOutOfThePrompt() {
        val h = harness()
        h.presenter.attach(doc)
        h.sender!!.finish(AttachmentOutcome.Failed("notes.pdf", UploadFailure.TooLarge))
        val ui = h.presenter.ui.value
        assertTrue(ui.attachedPaths.isEmpty())
        assertEquals(UploadFailure.TooLarge, ui.attachments.single().failure)
        h.presenter.onTextChanged("hi")
        h.presenter.send()
        assertEquals(listOf("prompt:A:hi"), h.port.calls)
        h.presenter.removeFailedAttachment(ui.attachments.single().failedKey!!)
        assertTrue(h.presenter.ui.value.attachments.isEmpty())
    }

    @Test
    fun aPictureKeepsItsPreviewUri() {
        val h = harness()
        h.presenter.attach(AttachmentSource.Photo("content://photo/9"))
        h.sender!!.finish(AttachmentOutcome.Sent("Photo-1.jpg", "/work/app/Photo-1.jpg", thumbnailUri = "content://photo/9"))
        assertEquals("content://photo/9", h.presenter.ui.value.attachments.single().thumbnailUri)
    }

    @Test
    fun nothingCanBeAttachedWhileTheAgentWorksOrWithoutASender() {
        val working = harness(AgentSessionState.WORKING)
        assertFalse(working.presenter.ui.value.canAttach)
        working.presenter.attach(doc)
        assertTrue(working.sender!!.folders.isEmpty())
        val unsupported = harness(sender = null)
        assertFalse(unsupported.presenter.ui.value.canAttach)
        unsupported.presenter.attach(doc)
        assertNull(unsupported.presenter.ui.value.uploadingName)
    }

    @Test
    fun theFileLandsOnTheChatThatAskedEvenIfAnotherIsOpenNow() {
        val chats = AgentChatState(listOf(session("A", "/a"), session("B", "/b")), "A")
        val h = Harness(chats, HeldSender())
        h.presenter.attach(doc)
        h.port.chatState.value = chats.copy(selectedSessionID = "B")
        assertNull(h.presenter.ui.value.uploadingName)
        h.sender!!.finish(AttachmentOutcome.Sent("notes.pdf", "/a/notes.pdf"))
        assertTrue(h.presenter.ui.value.attachedPaths.isEmpty())
        h.port.chatState.value = chats.copy(selectedSessionID = "A")
        assertEquals(listOf("/a/notes.pdf"), h.presenter.ui.value.attachedPaths)
    }
}

package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.files.DirectoryModel
import pl.dmq.peering.session.files.FileBrowserState

class FileShellActionsTest {
    private class Shell : ShellActions {
        val running = MutableStateFlow(true)
        val typed = mutableListOf<String>()
        val ran = mutableListOf<String>()

        override val ready: StateFlow<Boolean> get() = running

        override fun putPath(path: String) {
            typed += path
        }

        override fun run(path: String) {
            ran += path
        }
    }

    private val script = file("deploy.sh", permissions = "-rwxr-xr-x")
    private val notes = file("notes.txt")
    private val state = FileBrowserState(listing = DirectoryModel("/Users/me/app", listOf(script, notes), isTruncated = false))

    private fun presenter(shell: Shell?) = FileListPresenter(FakeFileBrowsingPort(state).also { it.shell = shell }, CoroutineScope(UnconfinedTestDispatcher()))

    private fun FileListPresenter.select(name: String) = toggleSelected(ui.value.entries.first { it.name == name })

    @Test
    fun `a selected file's path goes to the shell in use and the selection ends`() = runTest {
        val shell = Shell()
        val presenter = presenter(shell)
        presenter.select("notes.txt")

        presenter.putSelectedPathInShell()

        assertEquals(listOf("/Users/me/app/notes.txt"), shell.typed)
        assertFalse(presenter.ui.value.isSelecting)
    }

    @Test
    fun `running asks first and runs only an executable file on a yes`() = runTest {
        val shell = Shell()
        val presenter = presenter(shell)
        presenter.select("deploy.sh")

        presenter.beginRunSelected()
        assertEquals(FileDialog.ConfirmRun(script), presenter.ui.value.dialog)
        assertTrue(shell.ran.isEmpty())

        presenter.confirmRun()
        assertEquals(listOf("/Users/me/app/deploy.sh"), shell.ran)
        assertEquals(null, presenter.ui.value.dialog)
    }

    @Test
    fun `a file that is not executable cannot be run`() = runTest {
        val shell = Shell()
        val presenter = presenter(shell)
        presenter.select("notes.txt")

        presenter.beginRunSelected()

        assertEquals(null, presenter.ui.value.dialog)
        assertTrue(shell.ran.isEmpty())
    }

    @Test
    fun `without a shell nothing is offered or sent`() = runTest {
        val presenter = presenter(null)
        presenter.select("deploy.sh")

        presenter.putSelectedPathInShell()
        presenter.beginRunSelected()

        assertFalse(presenter.ui.value.canUseShell)
        assertEquals(null, presenter.ui.value.dialog)
    }

    @Test
    fun `the shell is offered only while one is running`() = runTest {
        val shell = Shell()
        val presenter = presenter(shell)
        assertTrue(presenter.ui.value.canUseShell)

        shell.running.value = false

        assertFalse(presenter.ui.value.canUseShell)
    }
}

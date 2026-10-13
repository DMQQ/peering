package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KeyboardHostFieldTest {
    private var now = 0L
    private val presenter = KeyboardPresenter(RecordingCommandSink(), nowMillis = { now })

    @Test
    fun `the computer's field text fills the typing line when nobody is typing`() {
        presenter.onHostField("Dear Sam,")

        assertEquals("Dear Sam,", presenter.typedPreview.value)
    }

    @Test
    fun `a report that arrives while typing waits and then shows`() {
        now = 1_000
        presenter.onSoftKeyboardText("hi")
        now = 1_200

        presenter.onHostField("older text")
        assertEquals("hi", presenter.typedPreview.value)
        assertEquals(600L, presenter.hostFieldWait())

        now = 1_800
        presenter.releaseHostField()
        assertEquals("older text", presenter.typedPreview.value)
        assertNull(presenter.hostFieldWait())
    }

    @Test
    fun `a moved focus empties the line and drops what was waiting`() {
        now = 1_000
        presenter.onSoftKeyboardText("draft")
        presenter.onHostField("held")

        presenter.onHostFocusMoved()
        now = 5_000
        presenter.releaseHostField()

        assertEquals("", presenter.typedPreview.value)
    }
}

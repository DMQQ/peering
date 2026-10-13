package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AddVirtualDisplay
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PerformWindowAction
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.RefreshSpacePreviews
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.RemoveVirtualDisplay
import pl.dmq.peering.wire.RenameVirtualDisplay
import pl.dmq.peering.wire.SpaceDisplay
import pl.dmq.peering.wire.SwitchToSpace
import pl.dmq.peering.wire.WindowAction

class SourcesDesktopsAndDisplaysTest {
    private val sink = RecordingCommandSink()
    private val presenter = SourcesPresenter(sink)
    private val mac = SourcesFeatures(windowControls = true, virtualDisplays = true, desktops = true)

    @Test
    fun `switching to a desktop sends the display and its position`() {
        presenter.switchToDesktop(display = 7, index = 2)
        presenter.refreshDesktops()

        assertEquals(listOf<RemoteCommand>(SwitchToSpace(7, 2), RefreshSpacePreviews), sink.sent)
    }

    @Test
    fun `a tap on a desktop answers for its display until the computer does`() {
        val display = SpaceDisplay(displayId = 1, count = 3, current = 1, previews = emptyList())
        val pending = PendingDesktop(display = 1, index = 3)

        assertTrue(desktopIsCurrent(display, 3, pending))
        assertFalse(desktopIsCurrent(display, 1, pending))
        assertTrue(desktopIsCurrent(display, 1, null))
    }

    @Test
    fun `a tap on another display leaves this one as the computer reports it`() {
        val display = SpaceDisplay(displayId = 1, count = 3, current = 2, previews = emptyList())

        assertTrue(desktopIsCurrent(display, 2, PendingDesktop(display = 9, index = 3)))
    }

    @Test
    fun `a screen is named with two screens, or when a full screen app hides its desktop and it is shown`() {
        val onDesktop = SpaceDisplay(1, 2, current = 1, previews = emptyList())
        val fullScreen = SpaceDisplay(1, 2, current = null, previews = emptyList())

        assertTrue(namesScreen(2, showing = false, display = onDesktop))
        assertFalse(namesScreen(1, showing = true, display = onDesktop))
        assertTrue(namesScreen(1, showing = true, display = fullScreen))
        assertFalse(namesScreen(1, showing = false, display = fullScreen))
    }

    @Test
    fun `adding a display asks for the phone shaped landscape display with no name`() {
        presenter.addVirtualDisplay()

        assertEquals(listOf<RemoteCommand>(AddVirtualDisplay("", 1290, 2796, true)), sink.sent)
    }

    @Test
    fun `renaming trims the name and a blank one sends nothing`() {
        assertTrue(presenter.renameVirtualDisplay(4, "  Desk  "))
        assertFalse(presenter.renameVirtualDisplay(4, "   "))

        assertEquals(listOf<RemoteCommand>(RenameVirtualDisplay(4, "Desk")), sink.sent)
    }

    @Test
    fun `a window offers close, minimise and zoom on a Mac and nothing on a host without controls`() {
        val window = descriptor(CaptureSource.Window(12))

        assertEquals(listOf(TileAction.CLOSE, TileAction.MINIMISE, TileAction.ZOOM), presenter.actionsFor(window, mac))
        assertEquals(emptyList<TileAction>(), presenter.actionsFor(window, SourcesFeatures()))
    }

    @Test
    fun `window actions send the window and the action`() {
        val window = descriptor(CaptureSource.Window(12))

        presenter.perform(window, TileAction.CLOSE)
        presenter.perform(window, TileAction.MINIMISE)
        presenter.perform(window, TileAction.ZOOM)

        assertEquals(
            listOf<RemoteCommand>(
                PerformWindowAction(12, WindowAction.CLOSE),
                PerformWindowAction(12, WindowAction.MINIMIZE),
                PerformWindowAction(12, WindowAction.ZOOM),
            ),
            sink.sent,
        )
    }

    @Test
    fun `only a display this phone added can be removed or renamed`() {
        val added = descriptor(CaptureSource.Display(5), managed = true)
        val real = descriptor(CaptureSource.Display(1))

        assertEquals(listOf(TileAction.REMOVE, TileAction.RENAME), presenter.actionsFor(added, mac))
        assertEquals(emptyList<TileAction>(), presenter.actionsFor(real, mac))
        assertEquals(emptyList<TileAction>(), presenter.actionsFor(added, SourcesFeatures(windowControls = true)))

        presenter.perform(added, TileAction.REMOVE)
        assertEquals(listOf<RemoteCommand>(RemoveVirtualDisplay(5)), sink.sent)
    }

    private fun descriptor(source: CaptureSource, managed: Boolean = false) = CaptureSourceDescriptor(
        id = source.stableId,
        kind = if (source is CaptureSource.Window) CaptureSourceKind.WINDOW else CaptureSourceKind.DISPLAY,
        title = "t",
        source = source,
        pixelSize = PixelSize(1.0, 1.0),
        isManagedVirtualDisplay = managed,
    )
}

package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.SetCaptureSource

class SourcesPresenterTest {
    private val sink = RecordingCommandSink()
    private val presenter = SourcesPresenter(sink)

    @Test
    fun `each display becomes a tile with its title and pixel size`() {
        val catalog = CaptureCatalog(displays = listOf(display(1, "Built-in", 3024.0, 1964.0), display(2, "Studio", 2560.0, 1440.0)))

        val state = presenter.build(catalog, chosen = null)

        val tiles = state.sections.single().tiles
        assertEquals(listOf("Built-in", "Studio"), tiles.map { it.title })
        assertEquals(PixelSize(2560.0, 1440.0), tiles[1].pixelSize)
    }

    @Test
    fun `only the chosen source is marked selected`() {
        val catalog = CaptureCatalog(displays = listOf(display(1, "A", 1.0, 1.0), display(2, "B", 1.0, 1.0)))

        val tiles = presenter.build(catalog, chosen = CaptureSource.Display(2)).sections.single().tiles

        assertEquals(listOf(false, true), tiles.map { it.selected })
    }

    @Test
    fun `a Windows host that sends only displays shows only the displays section`() {
        val catalog = CaptureCatalog(displays = listOf(display(1, "Screen", 1920.0, 1080.0)))

        val kinds = presenter.build(catalog, chosen = null).sections.map { it.kind }

        assertEquals(listOf(CaptureSourceKind.DISPLAY), kinds)
    }

    @Test
    fun `application and window sections appear in order only when the host has some`() {
        val catalog = CaptureCatalog(
            displays = listOf(display(1, "Screen", 1.0, 1.0)),
            applications = listOf(application(42, "Notes")),
            windows = listOf(window(7, "Terminal")),
        )

        val sections = presenter.build(catalog, chosen = null).sections

        assertEquals(
            listOf(CaptureSourceKind.DISPLAY, CaptureSourceKind.APPLICATION, CaptureSourceKind.WINDOW),
            sections.map { it.kind },
        )
        assertEquals("Notes", sections[1].tiles.single().title)
    }

    @Test
    fun `no catalogue yet shows the displays section empty`() {
        val state = presenter.build(catalog = null, chosen = null)

        assertEquals(listOf(CaptureSourceKind.DISPLAY), state.sections.map { it.kind })
        assertTrue(state.sections.single().tiles.isEmpty())
    }

    @Test
    fun `choosing a display sends it as the capture source`() {
        val tile = presenter.build(CaptureCatalog(displays = listOf(display(5, "Desk", 1.0, 1.0))), null)
            .sections.single().tiles.single()

        presenter.choose(tile)

        assertEquals(listOf<RemoteCommand>(SetCaptureSource(CaptureSource.Display(5))), sink.sent)
    }

    @Test
    fun `choosing a window sends the window as the capture source`() {
        val tile = presenter.build(CaptureCatalog(windows = listOf(window(9, "Notes"))), null)
            .sections.flatMap { it.tiles }.single()

        presenter.choose(tile)

        assertEquals(listOf<RemoteCommand>(SetCaptureSource(CaptureSource.Window(9))), sink.sent)
    }

    private fun display(id: Long, title: String, width: Double, height: Double) = CaptureSourceDescriptor(
        id = "display:$id",
        kind = CaptureSourceKind.DISPLAY,
        title = title,
        source = CaptureSource.Display(id),
        pixelSize = PixelSize(width, height),
    )

    private fun application(pid: Int, title: String) = CaptureSourceDescriptor(
        id = "application:$pid",
        kind = CaptureSourceKind.APPLICATION,
        title = title,
        source = CaptureSource.Application(pid),
        pixelSize = PixelSize(1.0, 1.0),
    )

    private fun window(id: Long, title: String) = CaptureSourceDescriptor(
        id = "window:$id",
        kind = CaptureSourceKind.WINDOW,
        title = title,
        source = CaptureSource.Window(id),
        pixelSize = PixelSize(1.0, 1.0),
    )
}

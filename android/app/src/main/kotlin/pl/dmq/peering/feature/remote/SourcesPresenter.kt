package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.session.video.MosaicGrid
import pl.dmq.peering.wire.LaunchApplication
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.OpenNewWindow
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.WatchSourceThumbnails

/** Turns the host's catalogue into the sources sheet, and sends the user's choice to the Mac. */
class SourcesPresenter(private val sink: CommandSink) {
    /** A null catalogue is one not received yet, and shows as an empty list of displays. */
    fun build(catalog: CaptureCatalog?, chosen: CaptureSource?): SourcesState {
        val known = catalog ?: CaptureCatalog()
        val sections = listOf(
            section(CaptureSourceKind.DISPLAY, known.displays, chosen),
            section(CaptureSourceKind.APPLICATION, known.applications, chosen),
            section(CaptureSourceKind.WINDOW, known.windows, chosen),
        )
        return SourcesState(sections.filter { it.kind == CaptureSourceKind.DISPLAY || it.tiles.isNotEmpty() })
    }

    /** While the sheet is open the host keeps its pictures fresh. The session drops this for a host that cannot. */
    fun watchThumbnails(watching: Boolean) {
        sink.send(WatchSourceThumbnails(watching))
    }

    fun choose(tile: SourceTile) {
        sink.send(SetCaptureSource(tile.source))
    }

    /** Asks the computer for a mosaic of [picks] sized to a screen of [viewport] pixels. False when the picks are not a mosaic. */
    fun showMosaic(picks: MosaicPicks, viewport: PixelSize, catalog: CaptureCatalog?): Boolean {
        if (!picks.canStart) return false
        val layout = MosaicGrid.layout(picks.sources, viewport, catalog) ?: return false
        sink.send(SetCaptureSource(CaptureSource.Mosaic(layout)))
        return true
    }

    /** Asks for [layout] again, the mosaic left earlier in this session. */
    fun returnToMosaic(layout: MosaicLayout) {
        sink.send(SetCaptureSource(CaptureSource.Mosaic(layout)))
    }

    /** Opens a new window in the application on the computer, which then appears among its windows. */
    fun openNewWindow(bundleIdentifier: String) {
        sink.send(OpenNewWindow(bundleIdentifier))
    }

    /** Opens an application the computer has installed and is not running. */
    fun launch(application: InstalledApplication) {
        sink.send(LaunchApplication(application.bundleIdentifier))
    }

    /** One descriptor as the tile the panel draws, marked when it is what the picture shows. */
    fun tile(descriptor: CaptureSourceDescriptor, chosen: CaptureSource?): SourceTile = tile(descriptor, descriptor.source == chosen)

    fun tile(descriptor: CaptureSourceDescriptor, selected: Boolean): SourceTile = SourceTile(
        source = descriptor.source,
        kind = descriptor.kind,
        title = descriptor.title,
        subtitle = descriptor.subtitle,
        pixelSize = descriptor.pixelSize,
        selected = selected,
        iconData = descriptor.iconPNGData,
        thumbnail = descriptor.thumbnail,
    )

    private fun section(
        kind: CaptureSourceKind,
        descriptors: List<CaptureSourceDescriptor>,
        chosen: CaptureSource?,
    ): SourceSection = SourceSection(
        kind = kind,
        tiles = descriptors.map { tile(it, chosen) },
    )
}

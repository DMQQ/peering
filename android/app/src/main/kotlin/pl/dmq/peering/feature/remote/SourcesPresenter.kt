package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.SetCaptureSource

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

    fun choose(tile: SourceTile) {
        sink.send(SetCaptureSource(tile.source))
    }

    private fun section(
        kind: CaptureSourceKind,
        descriptors: List<CaptureSourceDescriptor>,
        chosen: CaptureSource?,
    ): SourceSection = SourceSection(
        kind = kind,
        tiles = descriptors.map { descriptor ->
            SourceTile(
                source = descriptor.source,
                title = descriptor.title,
                subtitle = descriptor.subtitle,
                pixelSize = descriptor.pixelSize,
                selected = descriptor.source == chosen,
            )
        },
    )
}

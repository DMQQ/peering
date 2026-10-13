package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.session.video.MosaicArrangement
import pl.dmq.peering.session.video.MosaicEdit
import pl.dmq.peering.session.video.MosaicGrid
import pl.dmq.peering.wire.AddVirtualDisplay
import pl.dmq.peering.wire.LaunchApplication
import pl.dmq.peering.wire.PerformWindowAction
import pl.dmq.peering.wire.RefreshSpacePreviews
import pl.dmq.peering.wire.RemoveVirtualDisplay
import pl.dmq.peering.wire.RenameVirtualDisplay
import pl.dmq.peering.wire.SwitchToSpace
import pl.dmq.peering.wire.WindowAction
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.OpenNewWindow
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.WatchSourceThumbnails

/** Turns the host's catalogue into the sources sheet, and sends the user's choice to the Mac. */
class SourcesPresenter(private val sink: CommandSink) {
    private var weights: Map<CaptureSource, Int> = emptyMap()

    /** The tiles of [layout] with the sizes the user gave them in this session. */
    fun arrangementOf(layout: MosaicLayout): MosaicArrangement = MosaicArrangement.of(layout.tiles.map { it.source }, weights)

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
        val layout = MosaicGrid.layout(MosaicArrangement.of(picks.sources, weights), viewport, catalog) ?: return false
        sink.send(SetCaptureSource(CaptureSource.Mosaic(layout)))
        return true
    }

    /**
     * Applies [edit] to the mosaic on screen and asks the computer for the result. An arrangement left with one tile is
     * not a mosaic, so that window is shown on its own. False when nothing was sent.
     */
    fun edit(current: MosaicLayout, edit: MosaicEdit, viewport: PixelSize, catalog: CaptureCatalog?): Boolean {
        val before = arrangementOf(current)
        val after = before.applying(edit)
        if (after == before) return false
        weights = weights + after.choices.associate { it.source to it.weight }
        if (!after.isMosaic) {
            val only = after.sources.firstOrNull() ?: return false
            sink.send(SetCaptureSource(only))
            return true
        }
        val layout = MosaicGrid.layout(after, viewport, catalog) ?: return false
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

    /** Moves [display] to its desktop [index]. The caller also makes that display the picture. */
    fun switchToDesktop(display: Long, index: Int) {
        sink.send(SwitchToSpace(display, index))
    }

    /** Asks for fresh pictures of the desktops, which change under the user while the panel is open. */
    fun refreshDesktops() {
        sink.send(RefreshSpacePreviews)
    }

    /** One fixed shape, a real phone panel in landscape: a virtual display is worked at like a monitor. */
    fun addVirtualDisplay() {
        sink.send(AddVirtualDisplay(name = "", width = VIRTUAL_DISPLAY_WIDTH, height = VIRTUAL_DISPLAY_HEIGHT, startLandscape = true))
    }

    fun removeVirtualDisplay(displayId: Long) {
        sink.send(RemoveVirtualDisplay(displayId))
    }

    /** False when [name] is blank, which the computer would refuse. */
    fun renameVirtualDisplay(displayId: Long, name: String): Boolean {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return false
        sink.send(RenameVirtualDisplay(displayId, trimmed))
        return true
    }

    /** What a long press on [descriptor] offers: a window's title bar buttons, or a managed virtual display's remove and rename. */
    fun actionsFor(descriptor: CaptureSourceDescriptor, features: SourcesFeatures): List<TileAction> = when (descriptor.source) {
        is CaptureSource.Window -> if (features.windowControls) listOf(TileAction.CLOSE, TileAction.MINIMISE, TileAction.ZOOM) else emptyList()
        is CaptureSource.Display ->
            if (descriptor.isManagedVirtualDisplay && features.virtualDisplays) listOf(TileAction.REMOVE, TileAction.RENAME) else emptyList()
        else -> emptyList()
    }

    /** Sends [action] for [descriptor]. Rename needs a name, so it goes through [renameVirtualDisplay] instead. */
    fun perform(descriptor: CaptureSourceDescriptor, action: TileAction) {
        val source = descriptor.source
        when {
            source is CaptureSource.Window && action == TileAction.CLOSE -> sink.send(PerformWindowAction(source.id, WindowAction.CLOSE))
            source is CaptureSource.Window && action == TileAction.MINIMISE -> sink.send(PerformWindowAction(source.id, WindowAction.MINIMIZE))
            source is CaptureSource.Window && action == TileAction.ZOOM -> sink.send(PerformWindowAction(source.id, WindowAction.ZOOM))
            source is CaptureSource.Display && action == TileAction.REMOVE -> removeVirtualDisplay(source.id)
        }
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

/** What the computer can do, as the panel offers it. A Windows host can do neither. */
data class SourcesFeatures(val windowControls: Boolean = false, val virtualDisplays: Boolean = false, val desktops: Boolean = false)

enum class TileAction { CLOSE, MINIMISE, ZOOM, REMOVE, RENAME }

const val MAX_MANAGED_DISPLAYS = 3
private const val VIRTUAL_DISPLAY_WIDTH = 1290
private const val VIRTUAL_DISPLAY_HEIGHT = 2796

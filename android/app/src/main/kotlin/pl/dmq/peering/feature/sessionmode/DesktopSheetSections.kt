package pl.dmq.peering.feature.sessionmode

import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.SpaceDisplay
import pl.dmq.peering.wire.spaces

/** One display's desktops in the dock's desktops sheet; [title] names the display only when there is more than one. */
data class DesktopSheetSection(val display: SpaceDisplay, val title: String?)

object DesktopSheetSections {
    fun of(catalog: CaptureCatalog?): List<DesktopSheetSection> {
        val displays = catalog?.spaces?.displays.orEmpty().filter { it.count > 0 }
        return displays.map { display ->
            val title = if (displays.size > 1) catalog?.displays?.firstOrNull { it.source == CaptureSource.Display(display.displayId) }?.title else null
            DesktopSheetSection(display, title)
        }
    }
}

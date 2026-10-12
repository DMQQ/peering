package pl.dmq.peering.feature.remote

/** The panel open after a dock button for [tapped] is pressed: the same button closes, another switches without closing. */
fun panelAfterTap(open: SessionPanel?, tapped: SessionPanel): SessionPanel? = if (open == tapped) null else tapped

/** What the floating surface holds: the panel to draw, kept as the last one while the surface is leaving. */
class PanelMemory {
    var panel: SessionPanel? = null
        private set

    fun shown(open: SessionPanel?): SessionPanel? {
        if (open != null) panel = open
        return panel
    }
}

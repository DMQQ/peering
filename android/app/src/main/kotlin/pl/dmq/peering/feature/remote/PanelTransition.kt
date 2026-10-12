package pl.dmq.peering.feature.remote

enum class PanelTransition { RISE, FALL, CROSSFADE, NONE }

/** Opening and closing move along the dock edge; one panel replacing another only fades, so nothing travels twice. */
fun panelTransition(from: SessionPanel?, to: SessionPanel?): PanelTransition = when {
    from == to -> PanelTransition.NONE
    from == null -> PanelTransition.RISE
    to == null -> PanelTransition.FALL
    else -> PanelTransition.CROSSFADE
}

package pl.dmq.peering.feature.remote

/** The sections to show, in order. Displays are always present; other sections only when the host has some. */
data class SourcesState(val sections: List<SourceSection>)

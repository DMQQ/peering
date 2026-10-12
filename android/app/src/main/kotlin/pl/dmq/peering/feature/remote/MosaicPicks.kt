package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout

/** The windows and screens picked for a mosaic, in the order they were picked, which is the order they are laid out. */
data class MosaicPicks(val sources: List<CaptureSource> = emptyList()) {
    /** Two is the fewest that is a mosaic; nine is the most the computer builds. */
    val canStart: Boolean get() = sources.size in MINIMUM..MosaicLayout.MAXIMUM_TILES

    val atLimit: Boolean get() = sources.size >= MosaicLayout.MAXIMUM_TILES

    /** One-based place of [source], or null when it is not picked. */
    fun place(source: CaptureSource): Int? = sources.indexOf(source).takeIf { it >= 0 }?.plus(1)

    /** Picks [source], or drops it when it is picked already. A tenth pick is refused. */
    fun toggled(source: CaptureSource): MosaicPicks = when {
        source in sources -> MosaicPicks(sources - source)
        atLimit -> this
        else -> MosaicPicks(sources + source)
    }

    companion object {
        const val MINIMUM = 2
    }
}

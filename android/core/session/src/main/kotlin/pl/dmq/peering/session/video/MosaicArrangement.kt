package pl.dmq.peering.session.video

import pl.dmq.peering.wire.CaptureSource

/** One tile of an arrangement: what it shows and how much of its row it takes relative to its neighbours. */
data class MosaicChoice(val source: CaptureSource, val weight: Int = MINIMUM_WEIGHT) {
    companion object {
        const val MINIMUM_WEIGHT = 1
        const val MAXIMUM_WEIGHT = 3
    }
}

/** A change the user makes to an arrangement. */
sealed interface MosaicEdit {
    data class Move(val from: Int, val to: Int) : MosaicEdit

    data class Remove(val index: Int) : MosaicEdit

    data class Resize(val index: Int, val step: Int) : MosaicEdit
}

/** The tiles of a mosaic in layout order, and the edits the user makes to them. Each edit returns a new arrangement. */
data class MosaicArrangement(val choices: List<MosaicChoice>) {
    val sources: List<CaptureSource> get() = choices.map { it.source }

    /** Moves the tile at [from] to place [to]; the others shift to make room. Out of range or unchanged is this arrangement. */
    fun moved(from: Int, to: Int): MosaicArrangement {
        if (from == to || from !in choices.indices || to !in choices.indices) return this
        val next = choices.toMutableList()
        next.add(to, next.removeAt(from))
        return MosaicArrangement(next)
    }

    fun removed(index: Int): MosaicArrangement =
        if (index in choices.indices) MosaicArrangement(choices.filterIndexed { i, _ -> i != index }) else this

    /** Steps the weight of the tile at [index] by [step], held between the minimum and the maximum. */
    fun resized(index: Int, step: Int): MosaicArrangement {
        val current = choices.getOrNull(index) ?: return this
        val weight = (current.weight + step).coerceIn(MosaicChoice.MINIMUM_WEIGHT, MosaicChoice.MAXIMUM_WEIGHT)
        if (weight == current.weight) return this
        return MosaicArrangement(choices.mapIndexed { i, choice -> if (i == index) choice.copy(weight = weight) else choice })
    }

    fun applying(edit: MosaicEdit): MosaicArrangement = when (edit) {
        is MosaicEdit.Move -> moved(edit.from, edit.to)
        is MosaicEdit.Remove -> removed(edit.index)
        is MosaicEdit.Resize -> resized(edit.index, edit.step)
    }

    /** Fewer than two tiles is not a mosaic: the one left, if any, is shown on its own. */
    val isMosaic: Boolean get() = choices.size >= MosaicGrid.MINIMUM_TILES

    companion object {
        fun of(sources: List<CaptureSource>, weights: Map<CaptureSource, Int> = emptyMap()) = MosaicArrangement(
            sources.map { MosaicChoice(it, (weights[it] ?: MosaicChoice.MINIMUM_WEIGHT).coerceIn(MosaicChoice.MINIMUM_WEIGHT, MosaicChoice.MAXIMUM_WEIGHT)) },
        )
    }
}

package pl.dmq.peering.ui.kit

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration

/** The window's width in Material's three steps. It follows the window, so a split screen or an unfolded phone changes it. */
enum class WidthClass {
    Compact,
    Medium,
    Expanded,
    ;

    /** Room for a list beside the thing it opens. */
    val twoPane: Boolean get() = this == Expanded

    companion object {
        const val MEDIUM_FROM_DP = 600
        const val EXPANDED_FROM_DP = 840

        fun of(widthDp: Int): WidthClass = when {
            widthDp >= EXPANDED_FROM_DP -> Expanded
            widthDp >= MEDIUM_FROM_DP -> Medium
            else -> Compact
        }
    }
}

@Composable
fun rememberWidthClass(): WidthClass = WidthClass.of(LocalConfiguration.current.screenWidthDp)

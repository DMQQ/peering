package pl.dmq.peering.ui.kit

import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.ui.Modifier

/** How a keyed list row moves when the list changes: the standard spec for placement and arrival, the exit spec for leaving. Rows already there when a screen opens do not animate. */
fun LazyItemScope.listItemMotion(): Modifier = Modifier.animateItem(Motion.standard(), Motion.standard(), Motion.exit())

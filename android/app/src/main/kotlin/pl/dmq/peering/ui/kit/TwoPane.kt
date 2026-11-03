package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** The width of the list beside a detail on a wide window. */
val LIST_PANE_WIDTH = 380.dp

/** A list beside its detail on a wide window, split by a hairline. With no [detail] the right pane shows [empty]. */
@Composable
fun TwoPane(
    list: @Composable () -> Unit,
    detail: (@Composable () -> Unit)?,
    empty: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    detailModifier: Modifier = Modifier,
) {
    Row(modifier.fillMaxSize()) {
        Box(Modifier.width(LIST_PANE_WIDTH).fillMaxHeight()) { list() }
        VerticalDivider(color = PeeringColors.hairline)
        Box(Modifier.weight(1f).fillMaxHeight().then(detailModifier), contentAlignment = Alignment.Center) {
            if (detail != null) detail() else empty()
        }
    }
}

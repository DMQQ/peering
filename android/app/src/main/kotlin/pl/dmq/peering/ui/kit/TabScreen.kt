package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * A root tab laid out as the phone's tabs are: a serif title with a one line detail, then blocks 18 apart on an 18 side
 * inset, scrolling as one column.
 */
@Composable
fun TabScreen(
    title: String,
    detail: String?,
    modifier: Modifier = Modifier,
    bottomClearance: Dp = 36.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp)
            .padding(top = 16.dp, bottom = bottomClearance),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Column(Modifier.fillMaxWidth().semantics { heading() }, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(title, style = PeeringText.display(size = 34f, tracking = -1.2f), color = PeeringColors.ink)
            if (detail != null) Text(detail, style = PeeringText.subheadline, color = PeeringColors.muted)
        }
        content()
    }
}

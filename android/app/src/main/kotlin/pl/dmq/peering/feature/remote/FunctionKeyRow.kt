package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R

/** F1 to F12 in a scrolling row. Each press is sent with the modifiers latched on the bar. */
@Composable
fun FunctionKeyRow(
    onKey: (FunctionKey) -> Unit,
    modifier: Modifier = Modifier,
) {
    val description = stringResource(R.string.remote_function_keys)
    LazyRow(
        modifier = modifier.semantics { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        contentPadding = PaddingValues(horizontal = 16.dp),
    ) {
        items(FunctionKey.entries) { key ->
            KeyCap(
                label = key.name,
                selected = false,
                outlinedInAccent = false,
                onClick = { onKey(key) },
            )
        }
    }
}

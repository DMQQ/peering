package pl.dmq.peering.feature.scan

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.kit.InkButton

/** The button that fixes a missing camera picture. */
internal class ScanAction(val label: String, val onClick: () -> Unit)

/** Why there is no camera picture: unavailable, not yet allowed, or switched off, with the one button that fixes it. */
@Composable
internal fun ScanMessage(
    icon: ImageVector,
    text: String,
    modifier: Modifier = Modifier,
    title: String = stringResource(R.string.scan_title),
    action: ScanAction? = null,
) {
    Box(modifier = modifier.fillMaxSize().padding(horizontal = 32.dp), contentAlignment = Alignment.Center) {
        EmptyState(
            icon = icon,
            title = title,
            body = text,
            action = action?.let { fix -> { InkButton(onClick = fix.onClick) { Text(fix.label) } } },
        )
    }
}

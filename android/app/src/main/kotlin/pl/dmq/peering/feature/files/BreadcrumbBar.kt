package pl.dmq.peering.feature.files

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors

/** The path to the folder on screen, one tappable step per folder, scrolled so the current folder is in view. */
@Composable
fun BreadcrumbBar(crumbs: List<FilePath.Breadcrumb>, onGoTo: (String) -> Unit, modifier: Modifier = Modifier) {
    val scroll = rememberScrollState()
    LaunchedEffect(crumbs) { scroll.scrollTo(scroll.maxValue) }
    Row(
        modifier = modifier.horizontalScroll(scroll).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        crumbs.forEachIndexed { index, crumb ->
            if (index > 0) {
                Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(16.dp))
            }
            val current = index == crumbs.lastIndex
            Box(
                modifier = Modifier
                    .heightIn(min = 48.dp)
                    .clickable(enabled = !current, role = Role.Button) { onGoTo(crumb.path) }
                    .padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    crumb.title,
                    style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace),
                    color = if (current) PeeringColors.ink else PeeringColors.muted,
                    maxLines = 1,
                )
            }
        }
    }
}


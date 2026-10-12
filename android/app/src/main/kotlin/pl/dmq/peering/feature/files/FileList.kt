package pl.dmq.peering.feature.files

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.TonalButton
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape

@Composable
fun FileList(presenter: FileListPresenter, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    val loading = stringResource(R.string.files_loading)
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Breadcrumbs(ui, onGoTo = presenter::goTo)
        ControlsRow(ui, presenter)
        if (ui.isRefreshing) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        when (ui.status) {
            FileListStatus.LOADING -> LinearProgressIndicator(
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = loading },
            )
            FileListStatus.ERROR -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(ui.failure.orEmpty(), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.danger)
                TonalButton(onClick = presenter::refresh) { Text(stringResource(R.string.files_retry)) }
            }
            FileListStatus.EMPTY -> EmptyState(
                icon = AppIcons.folder,
                title = stringResource(R.string.files_empty_title),
                body = stringResource(R.string.files_folder_empty),
                modifier = Modifier.padding(vertical = 24.dp),
            )
            FileListStatus.CONTENT -> {
                LazyColumn {
                    items(ui.entries, key = { it.name }) { entry ->
                        FileEntryRow(entry, onClick = { presenter.open(entry) })
                    }
                }
                if (ui.isTruncated) {
                    Text(stringResource(R.string.files_truncated), style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint)
                }
            }
        }
    }
}

@Composable
private fun Breadcrumbs(ui: FileListUi, onGoTo: (String) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ui.breadcrumbs.forEachIndexed { index, crumb ->
            if (index > 0) Text("/", style = MaterialTheme.typography.bodyMedium, color = PeeringColors.faint)
            val current = index == ui.breadcrumbs.lastIndex
            Text(
                crumb.title,
                style = MaterialTheme.typography.bodyMedium,
                color = if (current) PeeringColors.ink else PeeringColors.muted,
                maxLines = 1,
                modifier = Modifier.clickable(enabled = !current) { onGoTo(crumb.path) },
            )
        }
    }
}

@Composable
private fun ControlsRow(ui: FileListUi, presenter: FileListPresenter) {
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FileSort.entries.forEach { order ->
            FilterChip(
                selected = order == ui.sort,
                onClick = { presenter.setSort(order) },
                label = { Text(stringResource(sortLabel(order))) },
                shape = PillShape,
            )
        }
        FilterChip(
            selected = ui.showsHidden,
            onClick = presenter::toggleHidden,
            label = { Text(stringResource(R.string.files_show_hidden)) },
            leadingIcon = if (ui.showsHidden) {
                { Icon(AppIcons.check, contentDescription = null, modifier = Modifier.size(18.dp)) }
            } else {
                null
            },
            shape = PillShape,
        )
    }
    if (ui.canGoUp) {
        TextButton(onClick = presenter::up) {
            Icon(AppIcons.back, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.files_up_one_level), color = PeeringColors.muted)
        }
    }
}

private fun sortLabel(order: FileSort): Int = when (order) {
    FileSort.NAME -> R.string.files_sort_name
    FileSort.SIZE -> R.string.files_sort_size
    FileSort.MODIFIED -> R.string.files_sort_modified
}

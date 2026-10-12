package pl.dmq.peering.feature.files

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun FileList(presenter: FileListPresenter, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Breadcrumbs(ui, onGoTo = presenter::goTo)
        ControlsRow(ui, presenter)
        if (ui.isRefreshing) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        when (ui.status) {
            FileListStatus.LOADING -> Text(stringResource(R.string.files_loading), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
            FileListStatus.ERROR -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(ui.failure.orEmpty(), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.danger)
                Text(
                    stringResource(R.string.files_retry),
                    style = MaterialTheme.typography.labelLarge,
                    color = PeeringColors.ink,
                    modifier = Modifier.clickable(onClick = presenter::refresh),
                )
            }
            FileListStatus.EMPTY -> Text(stringResource(R.string.files_folder_empty), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
            FileListStatus.CONTENT -> {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FileSort.entries.forEach { order ->
            val selected = order == ui.sort
            Text(
                stringResource(sortLabel(order)),
                style = MaterialTheme.typography.labelLarge,
                color = if (selected) PeeringColors.accent else PeeringColors.muted,
                modifier = Modifier.clickable { presenter.setSort(order) },
            )
        }
        Row(modifier = Modifier.weight(1f), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.files_show_hidden), style = MaterialTheme.typography.labelMedium, color = PeeringColors.muted)
            Switch(checked = ui.showsHidden, onCheckedChange = { presenter.toggleHidden() }, modifier = Modifier.padding(start = 8.dp))
        }
    }
    if (ui.canGoUp) {
        Text(
            stringResource(R.string.files_up_one_level),
            style = MaterialTheme.typography.labelLarge,
            color = PeeringColors.muted,
            modifier = Modifier.clickable(onClick = presenter::up),
        )
    }
}

private fun sortLabel(order: FileSort): Int = when (order) {
    FileSort.NAME -> R.string.files_sort_name
    FileSort.SIZE -> R.string.files_sort_size
    FileSort.MODIFIED -> R.string.files_sort_modified
}

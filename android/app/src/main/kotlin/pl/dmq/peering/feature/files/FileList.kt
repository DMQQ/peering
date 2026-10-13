package pl.dmq.peering.feature.files

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

/** The folder's rows, pulled down to list again, or the reason there are none. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileList(ui: FileListUi, presenter: FileListPresenter, modifier: Modifier = Modifier) {
    PullToRefreshBox(isRefreshing = ui.isRefreshing, onRefresh = presenter::refresh, modifier = modifier.fillMaxSize()) {
        if (ui.status == FileListStatus.CONTENT) {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                if (ui.canGoUp) {
                    item(key = UP_KEY) {
                        UpRow(onClick = { presenter.up() })
                        if (ui.entries.isNotEmpty()) RowDivider()
                    }
                }
                itemsIndexed(ui.entries, key = { _, row -> row.name }) { index, row ->
                    if (index > 0) RowDivider()
                    FileEntryRow(row, onClick = { presenter.tap(row) }, onLongClick = { presenter.toggleSelected(row) })
                }
                if (ui.isTruncated) {
                    item {
                        if (ui.entries.isNotEmpty()) RowDivider()
                        Text(
                            stringResource(R.string.files_truncated),
                            style = MaterialTheme.typography.bodySmall,
                            color = PeeringColors.faint,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                        )
                    }
                }
            }
        } else {
            FileListMessage(ui, onRetry = presenter::refresh, modifier = Modifier.verticalScroll(rememberScrollState()))
        }
    }
}

/** The iPhone's divider: white at 7 percent, edge to edge. */
@Composable
private fun RowDivider() {
    HorizontalDivider(thickness = Dp.Hairline, color = PeeringColors.ink.copy(alpha = 0.07f))
}

private const val UP_KEY = ".."

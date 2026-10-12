package pl.dmq.peering.feature.files

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
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
                items(ui.entries, key = { it.name }) { row ->
                    FileEntryRow(row, onClick = { presenter.tap(row) }, onLongClick = { presenter.toggleSelected(row) })
                }
                if (ui.isTruncated) {
                    item {
                        Text(
                            stringResource(R.string.files_truncated),
                            style = MaterialTheme.typography.bodySmall,
                            color = PeeringColors.faint,
                            modifier = Modifier.padding(16.dp),
                        )
                    }
                }
                item { Spacer(Modifier.height(FAB_CLEARANCE)) }
            }
        } else {
            FileListMessage(ui, onRetry = presenter::refresh, modifier = Modifier.verticalScroll(rememberScrollState()))
        }
    }
}

private val FAB_CLEARANCE = 88.dp

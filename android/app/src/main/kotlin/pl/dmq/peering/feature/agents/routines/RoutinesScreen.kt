package pl.dmq.peering.feature.agents.routines

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentIcons
import pl.dmq.peering.feature.agents.FolderPage
import pl.dmq.peering.feature.agents.FolderPicker
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Every routine on the computer, each with its last run, and the editor and folder page it opens. Covers the hub like the review screen does. */
@Composable
fun RoutinesScreen(presenter: RoutinesPresenter, folders: FolderPicker, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    val recents by presenter.recentFolders.collectAsState()
    LaunchedEffect(presenter) { presenter.refresh() }
    BackHandler { if (!presenter.back()) onClose() }
    Surface(modifier.fillMaxSize(), color = PeeringColors.backdrop) {
        when (val page = ui.page) {
            RoutinesPage.List -> RoutinesList(ui, presenter, onClose)
            is RoutinesPage.Editor -> RoutineEditor(page, ui.agents, presenter)
            is RoutinesPage.Folder -> FolderPage(
                folders = folders,
                recentFolders = recents,
                onUseFolder = { presenter.useChosenFolder() },
                onUseRecent = { presenter.useRecentFolder(it) },
                onBack = { presenter.back() },
            )
        }
    }
}

@Composable
private fun RoutinesList(ui: RoutinesUi, presenter: RoutinesPresenter, onClose: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose) {
                Icon(AppIcons.close, contentDescription = stringResource(R.string.routines_close), tint = PeeringColors.ink)
            }
            Text(stringResource(R.string.routines_title), style = PeeringText.headline, color = PeeringColors.ink, modifier = Modifier.weight(1f))
            IconButton(onClick = presenter::startNew, enabled = ui.agents.isNotEmpty()) {
                Icon(
                    AgentIcons.plus,
                    contentDescription = stringResource(R.string.routines_new),
                    tint = if (ui.agents.isNotEmpty()) PeeringColors.ink else PeeringColors.faint,
                )
            }
        }
        LazyColumn(
            Modifier.fillMaxSize().navigationBarsPadding(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ui.failure?.let { failure -> item(key = "failure") { Text(failure, style = PeeringText.footnote, color = PeeringColors.danger) } }
            val routines = ui.routines
            if (routines == null) {
                item(key = "loading") {
                    Row(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalArrangement = Arrangement.Center) { PeeringSpinner() }
                }
            } else {
                if (routines.isEmpty()) {
                    item(key = "empty") {
                        Text(stringResource(R.string.routines_empty_body), style = PeeringText.footnote, color = PeeringColors.muted, modifier = Modifier.padding(top = 8.dp))
                    }
                }
                items(routines, key = { it.id }) { routine ->
                    RoutineRow(routine, onEdit = { presenter.edit(routine) }, onRunNow = { presenter.runNow(routine.id) })
                }
            }
        }
    }
}

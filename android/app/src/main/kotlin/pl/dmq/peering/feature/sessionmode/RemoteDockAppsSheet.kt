package pl.dmq.peering.feature.sessionmode

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.ApplicationIcon
import pl.dmq.peering.feature.remote.SectionTitle
import pl.dmq.peering.feature.remote.SourceGrouping
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.CaptureCatalog

private data class AppEntry(val key: String, val bundleIdentifier: String?, val title: String, val iconData: String?)

/** Every app on the computer: pinned ones on top, then what is running, then the rest installed. A tap brings one forward; a long press pins or unpins it. */
@Composable
fun RemoteDockAppsSheet(catalog: CaptureCatalog?, favourites: ApplicationFavourites?, onLaunch: (String) -> Unit, onDismiss: () -> Unit) {
    var version by remember { mutableIntStateOf(0) }
    val sections = remember(catalog, version) { sections(catalog, favourites) }
    val toggle: (String) -> Unit = { bundle ->
        favourites?.toggle(bundle)
        version++
    }
    PeeringSheet(onDismiss, partiallyExpandable = true) {
        LazyVerticalGrid(
            GridCells.Adaptive(72.dp),
            Modifier.fillMaxWidth().padding(horizontal = 18.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                SheetHeader(stringResource(R.string.remote_dock_apps), stringResource(R.string.dock_apps_hint))
            }
            val launch: (AppEntry) -> Unit = { entry ->
                entry.bundleIdentifier?.let(onLaunch)
                onDismiss()
            }
            group(R.string.dock_apps_favourites, sections.favourites, launch, toggle)
            group(R.string.dock_apps_running, sections.running, launch, toggle)
            group(R.string.dock_apps_installed, sections.installed, launch, toggle)
        }
    }
}

private fun sections(catalog: CaptureCatalog?, favourites: ApplicationFavourites?): ApplicationSections<AppEntry> {
    val running = catalog?.applications.orEmpty().map { AppEntry("running.${it.id}", it.bundleIdentifier, it.title, it.iconPNGData) }
    val installed = catalog?.let { SourceGrouping.installedNotRunning(it, "") }.orEmpty()
        .map { AppEntry("installed.${it.bundleIdentifier}", it.bundleIdentifier, it.title, it.iconData) }
    return ApplicationSections.of(favourites?.bundleIdentifiers.orEmpty(), running, installed) { it.bundleIdentifier }
}

private fun LazyGridScope.group(titleRes: Int, entries: List<AppEntry>, onLaunch: (AppEntry) -> Unit, onToggle: (String) -> Unit) {
    if (entries.isEmpty()) return
    item(key = "title.$titleRes", span = { GridItemSpan(maxLineSpan) }) { SectionTitle(stringResource(titleRes)) }
    items(entries, key = { "$titleRes.${it.key}" }) { entry -> AppCell(entry, { onLaunch(entry) }, onToggle) }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AppCell(entry: AppEntry, onClick: () -> Unit, onToggle: (String) -> Unit) {
    val haptics = LocalHapticFeedback.current
    val bundle = entry.bundleIdentifier
    Column(
        Modifier.fillMaxWidth().combinedClickable(
            onClick = onClick,
            onLongClick = bundle?.let {
                {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onToggle(it)
                }
            },
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ApplicationIcon(entry.iconData, 64.dp)
        Text(entry.title, style = PeeringText.caption2, color = PeeringColors.ink, maxLines = 2, textAlign = TextAlign.Center)
    }
}

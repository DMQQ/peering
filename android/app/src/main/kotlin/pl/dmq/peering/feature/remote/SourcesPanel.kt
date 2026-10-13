package pl.dmq.peering.feature.remote

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SearchField
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.PixelSize

/**
 * The Apps panel: a search field, the screens as pictures, then one section per application with its windows as pictures
 * and a way to open another, then what is installed on the computer and not running. The computer is asked to keep the
 * pictures fresh while this is open.
 */
@Composable
fun SourcesPanel(
    catalog: CaptureCatalog?,
    chosen: CaptureSource?,
    presenter: SourcesPresenter,
    onPicked: () -> Unit,
    modifier: Modifier = Modifier,
    mosaic: MosaicPanel? = null,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var building by remember { mutableStateOf<MosaicPicks?>(null) }
    val metrics = LocalContext.current.resources.displayMetrics
    DisposableEffect(presenter) {
        presenter.watchThumbnails(true)
        onDispose { presenter.watchThumbnails(false) }
    }
    LazyColumn(modifier.fillMaxWidth(), contentPadding = PaddingValues(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item(key = "search") { SearchField(query, { query = it }, stringResource(R.string.sources_search), filled = true, height = 34.dp) }
        if (mosaic != null && building == null) item(key = "mosaic-entry") { MosaicEntry(mosaic, building, presenter, onBuild = { building = it }, onPicked) }
        val showing = mosaic?.active
        if (showing != null && building == null) {
            item(key = "mosaic-editor") {
                MosaicTileEditor(
                    editorTiles(presenter.arrangementOf(showing), catalog),
                    onEdit = { edit -> presenter.edit(showing, edit, PixelSize(metrics.widthPixels.toDouble(), metrics.heightPixels.toDouble()), catalog) },
                )
            }
        }
        building?.let { picks ->
            item(key = "mosaic-picker") {
                MosaicPickerBar(
                    picks,
                    onBack = { building = null },
                    onStart = {
                        if (presenter.showMosaic(picks, PixelSize(metrics.widthPixels.toDouble(), metrics.heightPixels.toDouble()), catalog)) {
                            building = null
                            onPicked()
                        }
                    },
                )
            }
        }
        sourceLists(catalog, chosen, building, query, presenter, onBuilding = { building = it }, onPicked)
    }
}

/** Lazy, so only the rows on screen are composed: a Mac with fifty apps open made every window preview and icon live at once. */
private fun LazyListScope.sourceLists(
    catalog: CaptureCatalog?,
    chosen: CaptureSource?,
    building: MosaicPicks?,
    query: String,
    presenter: SourcesPresenter,
    onBuilding: (MosaicPicks?) -> Unit,
    onPicked: () -> Unit,
) {
    if (catalog == null || (catalog.displays + catalog.applications + catalog.windows).isEmpty()) {
        item(key = "waiting") { Waiting() }
        return
    }
    val marking = Marking(chosen, building)
    val pick = { tile: SourceTile ->
        if (building != null) {
            onBuilding(building.toggled(tile.source))
        } else {
            presenter.choose(tile)
            onPicked()
        }
    }
    val screens = catalog.displays.filter { SourceGrouping.matches(it, query) }
    if (screens.isNotEmpty()) item(key = "screens") { Screens(screens, marking, presenter, pick) }
    val groups = SourceGrouping.filtered(SourceGrouping.applicationGroups(catalog.applications, catalog.windows), query)
    items(groups, key = { "app-${it.id}" }) { group -> ApplicationSection(group, marking, presenter, pick, onPicked) }
    if (building == null) installedGrid(SourceGrouping.installedNotRunning(catalog, query), presenter, onPicked)
}

@Composable
private fun Waiting() {
    Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(AppIcons.display, contentDescription = null, tint = PeeringColors.muted)
        Text(stringResource(R.string.sources_waiting), style = PeeringText.subheadline, color = PeeringColors.muted)
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text.uppercase(), style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.1.sp), color = PeeringColors.muted)
}

@Composable
private fun Screens(matches: List<CaptureSourceDescriptor>, marking: Marking, presenter: SourcesPresenter, pick: (SourceTile) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionTitle(stringResource(R.string.sources_section_screens))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            matches.forEach { display -> marking.tile(presenter, display).let { tile -> PreviewTile(tile, { pick(tile) }, badge = marking.place(display.source)) } }
        }
    }
}

@Composable
private fun ApplicationSection(
    group: ApplicationGroup,
    marking: Marking,
    presenter: SourcesPresenter,
    pick: (SourceTile) -> Unit,
    onPicked: () -> Unit,
) {
    val application = group.application?.let { marking.tile(presenter, it) }
    Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.fillMaxWidth().let { if (application != null) it.tappable({ pick(application) }) else it },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ApplicationIcon(group.iconData, 22.dp, AppIcons.window)
            val marked = application?.selected == true
            Text(
                group.title,
                style = PeeringText.subheadlineMedium,
                color = if (marked) PeeringColors.accent else PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (marked) Icon(AppIcons.checkCircle, contentDescription = null, tint = PeeringColors.accent, modifier = Modifier.size(14.dp))
            Text(
                pluralStringResource(R.plurals.sources_windows, group.windows.size, group.windows.size),
                style = PeeringText.caption2,
                color = PeeringColors.muted,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.weight(1f, fill = false).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                group.windows.forEach { window -> marking.tile(presenter, window).let { tile -> PreviewTile(tile, { pick(tile) }, badge = marking.place(window.source)) } }
            }
            group.bundleIdentifier?.takeIf { !marking.picking }?.let { bundle ->
                AddTile(stringResource(R.string.sources_new_window), {
                    presenter.openNewWindow(bundle)
                    onPicked()
                })
            }
        }
    }
}

private fun LazyListScope.installedGrid(installed: List<InstalledApplication>, presenter: SourcesPresenter, onPicked: () -> Unit) {
    if (installed.isEmpty()) return
    item(key = "installed-title") { SectionTitle(stringResource(R.string.sources_installed)) }
    items(installed.chunked(ICON_COLUMNS), key = { row -> "installed-${row.first().title}" }) { row ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            row.forEach { application ->
                Column(
                    Modifier.weight(1f).tappable({
                        presenter.launch(application)
                        onPicked()
                    }),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    ApplicationIcon(application.iconData, 56.dp)
                    Text(application.title, style = PeeringText.caption2.copy(fontSize = 10.sp), color = PeeringColors.ink, maxLines = 2, textAlign = TextAlign.Center)
                }
            }
            repeat(ICON_COLUMNS - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
    item(key = "installed-note") { Text(stringResource(R.string.sources_installed_note), style = PeeringText.caption2, color = PeeringColors.tertiary) }
}

private const val ICON_COLUMNS = 5

/** What marks a tile: the source on screen, or while a mosaic is being picked, the sources picked so far. */
private class Marking(private val chosen: CaptureSource?, private val picks: MosaicPicks?) {
    val picking: Boolean get() = picks != null

    fun place(source: CaptureSource): Int? = picks?.place(source)

    fun tile(presenter: SourcesPresenter, descriptor: CaptureSourceDescriptor): SourceTile =
        presenter.tile(descriptor, if (picks != null) picks.place(descriptor.source) != null else descriptor.source == chosen)
}

@Composable
private fun MosaicEntry(
    mosaic: MosaicPanel?,
    building: MosaicPicks?,
    presenter: SourcesPresenter,
    onBuild: (MosaicPicks?) -> Unit,
    onPicked: () -> Unit,
) {
    if (mosaic == null || building != null) return
    if (mosaic.arrangement == null) {
        MosaicEntryRow { onBuild(MosaicPicks()) }
    } else {
        MosaicEditRows(
            mosaic,
            onReturn = {
                mosaic.remembered?.let(presenter::returnToMosaic)
                onPicked()
            },
            onEdit = { onBuild(MosaicPicks(mosaic.sources)) },
        )
    }
}

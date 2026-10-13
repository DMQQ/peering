package pl.dmq.peering.feature.remote

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor

/** Longer than the host's retries to confirm a display, so an honest failure gives the spinner up and a success clears it sooner. */
private const val PENDING_MILLIS = 7_000L

/**
 * Its own group: a virtual display looks like a real monitor elsewhere in the panel, and this heading says everything
 * under it exists only in software. The host answers an add or a remove only by the catalogue changing shape.
 */
@Composable
internal fun VirtualDisplaysSection(
    displays: List<CaptureSourceDescriptor>,
    marking: Marking,
    features: SourcesFeatures,
    presenter: SourcesPresenter,
    pick: (SourceTile) -> Unit,
) {
    var adding by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(emptySet<String>()) }
    var renaming by remember { mutableStateOf<CaptureSourceDescriptor?>(null) }
    LaunchedEffect(displays.size) { adding = false }
    LaunchedEffect(displays.map { it.id }) { removing = removing.intersect(displays.map { it.id }.toSet()) }
    LaunchedEffect(adding) {
        if (adding) {
            delay(PENDING_MILLIS)
            adding = false
        }
    }
    LaunchedEffect(removing) {
        if (removing.isNotEmpty()) {
            delay(PENDING_MILLIS)
            removing = emptySet()
        }
    }
    val add = {
        adding = true
        presenter.addVirtualDisplay()
    }
    val atLimit = displays.size >= MAX_MANAGED_DISPLAYS
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionTitle(stringResource(R.string.sources_section_virtual))
        if (displays.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                AddTile(stringResource(R.string.sources_add_display), add, busy = adding)
                Text(stringResource(R.string.sources_virtual_empty), style = PeeringText.caption, color = PeeringColors.muted)
            }
        } else {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                displays.forEach { descriptor ->
                    val tile = marking.tile(presenter, descriptor)
                    val controls = presenter.actionsFor(descriptor, features).map { action ->
                        TileControl(action) {
                            when (action) {
                                TileAction.RENAME -> renaming = descriptor
                                TileAction.REMOVE -> {
                                    removing = removing + descriptor.id
                                    presenter.perform(descriptor, action)
                                }
                                else -> presenter.perform(descriptor, action)
                            }
                        }
                    }
                    PreviewTile(tile, { pick(tile) }, controls = controls, dimmed = descriptor.id in removing)
                }
                if (!atLimit) AddTile(stringResource(R.string.sources_add_display), add, busy = adding)
            }
        }
    }
    renaming?.let { target ->
        RenameDisplayDialog(
            current = target.title,
            onSave = { name ->
                val source = target.source as? CaptureSource.Display
                if (source != null) presenter.renameVirtualDisplay(source.id, name)
                renaming = null
            },
            onDismiss = { renaming = null },
        )
    }
}

@Composable
private fun RenameDisplayDialog(current: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var name by rememberSaveable { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = PeeringColors.sheet,
        title = { Text(stringResource(R.string.sources_rename_display)) },
        text = {
            Column {
                Spacer(Modifier.height(4.dp))
                PeeringTextField(name, { name = it }, stringResource(R.string.sources_rename_hint), Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton(onClick = { onSave(name) }, enabled = name.isNotBlank()) { Text(stringResource(R.string.sources_rename_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.sources_rename_cancel)) } },
    )
}

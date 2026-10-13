package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.style.TextOverflow
import pl.dmq.peering.ui.theme.PillShape
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.ChipKeyShape
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** What the Shortcuts panel sends and edits. */
class ShortcutsActions(
    val onKey: (keyCode: Int, modifiers: Long) -> Unit,
    val onTopRowAction: (keyCode: Int) -> Unit,
    val onModifier: (StickyModifier) -> Unit,
    val onDelete: () -> Unit,
    val onEnter: () -> Unit,
    val onEditMacros: () -> Unit,
)

private enum class ShortcutSet { APPLICATION, MACROS, FUNCTION_KEYS }

/**
 * The Shortcuts panel: a set picker (the application on screen, when it has a set, then Shortcuts and F1 to F12),
 * the keys of the chosen set, the latching modifiers, and Delete, Enter and the arrows.
 */
@Composable
fun ShortcutsPanel(
    profile: ApplicationProfile?,
    macros: List<Macro>,
    latches: Map<StickyModifier, ModifierLatch>,
    actions: ShortcutsActions,
    modifier: Modifier = Modifier,
) {
    var chosen by rememberSaveable { mutableStateOf<ShortcutSet?>(null) }
    val sets = listOfNotNull(ShortcutSet.APPLICATION.takeIf { profile != null }, ShortcutSet.MACROS, ShortcutSet.FUNCTION_KEYS)
    val shown = chosen?.takeIf { it in sets } ?: sets.first()
    Column(modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SetPicker(sets.map { it to setTitle(it, profile) }, shown) { chosen = it }
        Column(Modifier.heightIn(max = SETS_MAX_HEIGHT).verticalScroll(rememberScrollState())) {
            when (shown) {
                ShortcutSet.APPLICATION -> profile?.let { ApplicationKeys(it, actions) }
                ShortcutSet.MACROS -> MacroChips(macros, actions)
                ShortcutSet.FUNCTION_KEYS -> FunctionKeyGrid(actions)
            }
        }
        ModifierRow(latches, actions.onModifier)
        ArrowCluster(actions)
    }
}

/** The phone's segmented control: a track with the chosen set lifted on it. */
@Composable
private fun <T> SetPicker(items: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Row(Modifier.fillMaxWidth().height(32.dp).clip(PillShape).background(PeeringColors.ink.copy(alpha = 0.1f)).padding(2.dp)) {
        items.forEach { (item, title) ->
            val on = item == selected
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(PillShape)
                    .background(if (on) PeeringColors.ink.copy(alpha = 0.16f) else Color.Transparent)
                    .tappable({ onSelect(item) })
                    .semantics { this.selected = on },
                contentAlignment = Alignment.Center,
            ) {
                Text(title, style = PeeringText.subheadline, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 8.dp))
            }
        }
    }
}

@Composable
private fun setTitle(set: ShortcutSet, profile: ApplicationProfile?): String = when (set) {
    ShortcutSet.APPLICATION -> profile?.name.orEmpty()
    ShortcutSet.MACROS -> stringResource(R.string.remote_shortcuts_set)
    ShortcutSet.FUNCTION_KEYS -> stringResource(R.string.remote_shortcuts_function_keys)
}

@Composable
private fun ApplicationKeys(profile: ApplicationProfile, actions: ShortcutsActions) {
    KeyChipGrid(
        profile.actions.map { action ->
            KeyChip(action.id, { Text(action.title, style = CHIP_TEXT, color = PeeringColors.ink, maxLines = 1) }, action.detail) {
                actions.onKey(action.keyCode, action.modifiers)
            }
        },
    )
}

@Composable
private fun MacroChips(macros: List<Macro>, actions: ShortcutsActions) {
    val edit = stringResource(R.string.remote_macros_edit)
    KeyChipGrid(
        macros.map { macro ->
            KeyChip(macro.id, { Text(macro.title, style = CHIP_TEXT, color = PeeringColors.ink, maxLines = 1) }, macro.title) {
                actions.onKey(macro.keyCode, macro.modifiers)
            }
        } + KeyChip("edit", { Icon(AppIcons.tune, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(20.dp)) }, edit, actions.onEditMacros),
    )
}

/** A key chip: [content] is its face and [description] what is spoken for it. */
internal class KeyChip(val id: String, val content: @Composable () -> Unit, val description: String, val onClick: () -> Unit)

/** Chips in equal columns as many as fit at 76 dp, wrapping to rows. */
@Composable
internal fun KeyChipGrid(chips: List<KeyChip>) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = ((maxWidth + GAP) / (MIN_CHIP_WIDTH + GAP)).toInt().coerceAtLeast(1)
        Column(verticalArrangement = Arrangement.spacedBy(GAP)) {
            chips.chunked(columns).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(GAP)) {
                    row.forEach { chip -> ChipCell(chip, Modifier.weight(1f)) }
                    repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun ChipCell(chip: KeyChip, modifier: Modifier) {
    Box(
        modifier
            .heightIn(min = 44.dp)
            .clip(ChipKeyShape)
            .background(PeeringColors.ink.copy(alpha = 0.1f))
            .tappable(chip.onClick)
            .semantics { contentDescription = chip.description },
        contentAlignment = Alignment.Center,
    ) { chip.content() }
}

@Composable
private fun ArrowCluster(actions: ShortcutsActions) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PanelKey(SessionIcons.delete, stringResource(R.string.remote_key_delete), 64.dp, actions.onDelete)
        PanelKey(SessionIcons.enter, stringResource(R.string.remote_key_enter), 64.dp, actions.onEnter)
        Spacer(Modifier.weight(1f))
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            PanelKey(SessionIcons.up, stringResource(R.string.remote_arrow_up), 52.dp) { actions.onKey(UP, 0L) }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                PanelKey(SessionIcons.left, stringResource(R.string.remote_arrow_left), 52.dp) { actions.onKey(LEFT, 0L) }
                PanelKey(SessionIcons.down, stringResource(R.string.remote_arrow_down), 52.dp) { actions.onKey(DOWN, 0L) }
                PanelKey(SessionIcons.right, stringResource(R.string.remote_arrow_right), 52.dp) { actions.onKey(RIGHT, 0L) }
            }
        }
    }
}

@Composable
private fun PanelKey(icon: ImageVector, label: String, width: Dp, onClick: () -> Unit) {
    Box(
        Modifier
            .size(width = width, height = 40.dp)
            .clip(ChipKeyShape)
            .background(PeeringColors.ink.copy(alpha = 0.1f))
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(20.dp)) }
}

private val CHIP_TEXT = PeeringText.subheadlineMedium
private val GAP = 8.dp
private val MIN_CHIP_WIDTH = 76.dp
private val SETS_MAX_HEIGHT = 208.dp

package pl.dmq.peering.feature.terminal

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardReturn
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.DataObject
import androidx.compose.material.icons.outlined.Diamond
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.KeyboardHide
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.ui.graphics.vector.ImageVector

/** The glyphs only the terminal screen uses, kept out of the shared icon set. */
internal object TerminalGlyphs {
    val terminal: ImageVector get() = Icons.Outlined.Terminal
    val add: ImageVector get() = Icons.Outlined.Add
    val ellipsis: ImageVector get() = Icons.Outlined.MoreHoriz
    val history: ImageVector get() = Icons.Outlined.History
    val hideKeyboard: ImageVector get() = Icons.Outlined.KeyboardHide
    val returnKey: ImageVector get() = Icons.AutoMirrored.Outlined.KeyboardReturn
    val sendLine: ImageVector get() = Icons.Outlined.ArrowUpward
    val curlyBraces: ImageVector get() = Icons.Outlined.DataObject
    val paperPlane: ImageVector get() = Icons.AutoMirrored.Outlined.Send
    val diamond: ImageVector get() = Icons.Outlined.Diamond
    val wand: ImageVector get() = Icons.Outlined.AutoFixHigh
}

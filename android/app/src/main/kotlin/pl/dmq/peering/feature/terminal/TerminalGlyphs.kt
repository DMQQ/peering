package pl.dmq.peering.feature.terminal

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.ui.graphics.vector.ImageVector

/** The glyphs only the terminal screen uses, kept out of the shared icon set. */
internal object TerminalGlyphs {
    val terminal: ImageVector get() = Icons.Outlined.Terminal
    val add: ImageVector get() = Icons.Outlined.Add
    val paste: ImageVector get() = Icons.Outlined.ContentPaste
    val up: ImageVector get() = Icons.Outlined.KeyboardArrowUp
    val down: ImageVector get() = Icons.Outlined.KeyboardArrowDown
    val left: ImageVector get() = Icons.AutoMirrored.Outlined.KeyboardArrowLeft
    val right: ImageVector get() = Icons.AutoMirrored.Outlined.KeyboardArrowRight
}

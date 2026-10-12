package pl.dmq.peering.feature.files

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FolderSpecial
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.MusicNote
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.TextSnippet
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.ui.kit.AppIcons

val FileGlyph.icon: ImageVector
    get() = when (this) {
        FileGlyph.FOLDER -> AppIcons.folder
        FileGlyph.FOLDER_LINK -> Icons.Outlined.FolderSpecial
        FileGlyph.LINK -> Icons.Outlined.Link
        FileGlyph.EXECUTABLE -> Icons.Outlined.Terminal
        FileGlyph.IMAGE -> Icons.Outlined.Image
        FileGlyph.VIDEO -> Icons.Outlined.Movie
        FileGlyph.AUDIO -> Icons.Outlined.MusicNote
        FileGlyph.PDF -> Icons.Outlined.PictureAsPdf
        FileGlyph.ARCHIVE -> Icons.Outlined.FolderZip
        FileGlyph.MARKDOWN -> Icons.Outlined.TextSnippet
        FileGlyph.CODE -> Icons.Outlined.Code
        FileGlyph.TEXT -> Icons.Outlined.Description
        FileGlyph.GENERIC -> AppIcons.file
    }

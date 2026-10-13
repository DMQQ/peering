package pl.dmq.peering.feature.files

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.WrapText
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors

/** The open file's name, with line wrapping, share and download. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PreviewTopBar(ui: FilePreviewUi, presenter: FilePreviewPresenter) {
    TopAppBar(
        title = { Text(FilePath.name(ui.path), maxLines = 1) },
        navigationIcon = {
            IconButton(onClick = presenter::close) {
                Icon(AppIcons.close, contentDescription = stringResource(R.string.preview_close))
            }
        },
        actions = {
            if (ui.canWrap) {
                IconButton(onClick = presenter::toggleWrap) {
                    Icon(
                        Icons.AutoMirrored.Outlined.WrapText,
                        contentDescription = stringResource(if (ui.wraps) R.string.preview_scroll else R.string.preview_wrap),
                        tint = if (ui.wraps) PeeringColors.ink else PeeringColors.accent,
                    )
                }
            }
            if (ui.canShare) {
                IconButton(onClick = presenter::share) {
                    Icon(Icons.Outlined.Share, contentDescription = stringResource(R.string.preview_share))
                }
            }
            IconButton(onClick = presenter::download) {
                Icon(AppIcons.download, contentDescription = stringResource(R.string.preview_download))
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = Color.Transparent,
            titleContentColor = PeeringColors.ink,
            navigationIconContentColor = PeeringColors.ink,
            actionIconContentColor = PeeringColors.ink,
        ),
    )
}

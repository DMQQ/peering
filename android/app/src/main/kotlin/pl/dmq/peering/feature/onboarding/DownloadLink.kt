package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

private const val DOWNLOAD_URL = "https://getpeering.app/download"

/** The whole path written out and copyable: the host alone is not the address anybody types. */
@Composable
internal fun DownloadLink(modifier: Modifier = Modifier, compact: Boolean = false) {
    val uri = LocalUriHandler.current
    val clipboard = LocalClipboardManager.current
    val address = stringResource(R.string.tour_download_address)
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(2000)
            copied = false
        }
    }
    val openLabel = stringResource(R.string.tour_download_open)
    Row(modifier.fillMaxWidth().rowSurface(), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier
                .weight(1f)
                .tappable({ uri.openUri(DOWNLOAD_URL) })
                .semantics { contentDescription = openLabel }
                .padding(start = 16.dp, end = 4.dp, top = if (compact) 0.dp else 13.dp, bottom = if (compact) 0.dp else 13.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ShrinkingLine(
                address,
                (if (compact) PeeringText.subheadline else PeeringText.title3).copy(fontWeight = FontWeight.SemiBold),
                Modifier.weight(1f),
            )
            Icon(AppIcons.openExternal, null, tint = PeeringColors.muted, modifier = Modifier.size(18.dp))
        }
        Box(
            Modifier
                .size(44.dp)
                .tappable({ clipboard.setText(AnnotatedString(address)); copied = true })
                .semantics { contentDescription = "" },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (copied) AppIcons.check else AppIcons.copy,
                contentDescription = stringResource(if (copied) R.string.tour_download_copied else R.string.tour_download_copy),
                tint = if (copied) PeeringColors.ink else PeeringColors.muted,
                modifier = Modifier.size(20.dp),
            )
        }
        Box(Modifier.size(10.dp))
    }
}

/** One line that steps its size down, to 72 percent at most, until it fits: what iOS does with `minimumScaleFactor`. */
@Composable
private fun ShrinkingLine(text: String, style: TextStyle, modifier: Modifier) {
    var scale by remember { mutableFloatStateOf(1f) }
    Text(
        text,
        style = style.copy(fontSize = style.fontSize * scale),
        color = PeeringColors.ink,
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Clip,
        onTextLayout = { if (it.hasVisualOverflow && scale > 0.72f) scale = (scale - 0.04f).coerceAtLeast(0.72f) },
        modifier = modifier,
    )
}

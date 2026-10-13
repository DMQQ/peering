package pl.dmq.peering.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.Action
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.layout.Spacer
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import pl.dmq.peering.MainActivity
import pl.dmq.peering.R

internal val ink = ColorProvider(R.color.widget_ink)
internal val muted = ColorProvider(R.color.widget_ink_muted)
internal val faint = ColorProvider(R.color.widget_ink_faint)
internal val stateBlue = ColorProvider(R.color.widget_state_blue)
internal val failed = ColorProvider(R.color.widget_failed)

internal fun text(color: ColorProvider, size: Int, weight: FontWeight = FontWeight.Normal) =
    TextStyle(color = color, fontSize = size.sp, fontWeight = weight)

internal fun openLink(context: Context, link: String): Action {
    val request = WidgetLinkGate.requestFor(link, LinkNonce.load(context.noBackupFilesDir))
    return actionStartActivity(
        Intent(Intent.ACTION_VIEW, Uri.parse(request.data))
            .setClass(context, MainActivity::class.java)
            .putExtra(LinkNonce.EXTRA, request.nonce),
    )
}

@Composable
internal fun Icon(drawable: Int, color: ColorProvider, size: Int, modifier: GlanceModifier = GlanceModifier) {
    Image(
        provider = ImageProvider(drawable),
        contentDescription = null,
        colorFilter = ColorFilter.tint(color),
        modifier = modifier.size(size.dp),
    )
}

@Composable
internal fun Dot(drawable: Int) {
    Image(provider = ImageProvider(drawable), contentDescription = null, modifier = GlanceModifier.size(7.dp))
}

@Composable
internal fun Gap(width: Int) {
    Spacer(GlanceModifier.width(width.dp))
}

package pl.dmq.peering.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Column
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import pl.dmq.peering.R

/** Whether the phone has a session open to one of the computers, so a glance says whether it is up. */
class MacStatusWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetStore(context).quickConnect()
        provideContent { MacStatusContent(snapshot) }
    }
}

@Composable
private fun MacStatusContent(snapshot: QuickConnectSnapshot) {
    val context = LocalContext.current
    val connected = snapshot.computers.firstOrNull { it.id == snapshot.connectedId }
    val headline = connected ?: snapshot.computers.firstOrNull()
    val root = GlanceModifier.fillMaxSize().appWidgetBackground().background(ImageProvider(R.drawable.widget_container)).padding(12.dp)
    Column(modifier = root.clickable(openLink(context, WidgetLink.connect(headline?.id)))) {
        Icon(R.drawable.ic_widget_computer, if (connected == null) muted else stateBlue, 22)
        Spacer(GlanceModifier.defaultWeight())
        Text(
            context.getString(if (connected == null) R.string.widget_status_not_connected else R.string.widget_status_connected),
            style = text(ink, 15, FontWeight.Bold),
            maxLines = 2,
        )
        Text(
            headline?.name?.takeIf { it.isNotEmpty() } ?: context.getString(R.string.widget_status_none_paired),
            style = text(muted, 11),
            maxLines = 1,
        )
    }
}

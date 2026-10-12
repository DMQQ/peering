package pl.dmq.peering.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import pl.dmq.peering.R

/** Lists the trusted computers with a presence dot; a tap opens the app and connects to that one. */
class QuickConnectWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, WIDE, TALL))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetStore(context).quickConnect()
        provideContent { QuickConnectContent(snapshot) }
    }

    private companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
        val TALL = DpSize(250.dp, 200.dp)
    }
}

@Composable
private fun QuickConnectContent(snapshot: QuickConnectSnapshot) {
    val context = LocalContext.current
    val size = LocalSize.current
    val root = GlanceModifier.fillMaxSize().appWidgetBackground().background(ImageProvider(R.drawable.widget_container))
    if (size.width < 200.dp) {
        SmallTile(context, snapshot, root)
    } else {
        val rows = if (size.height >= 180.dp) 4 else 2
        ComputerList(context, snapshot, rows, root)
    }
}

@Composable
private fun SmallTile(context: Context, snapshot: QuickConnectSnapshot, root: GlanceModifier) {
    Column(
        modifier = root.padding(12.dp).clickable(openLink(context, WidgetLink.connect(snapshot.headline?.id))),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(R.drawable.ic_widget_computer, ink, 28)
        Spacer(GlanceModifier.height(6.dp))
        Text(
            text = snapshot.headline?.name?.takeIf { it.isNotEmpty() } ?: context.getString(R.string.app_name),
            style = text(ink, 15, FontWeight.Bold).copy(textAlign = TextAlign.Center),
            maxLines = 1,
        )
        Text(context.getString(R.string.widget_quick_connect_tap), style = text(muted, 11))
    }
}

@Composable
private fun ComputerList(context: Context, snapshot: QuickConnectSnapshot, rows: Int, root: GlanceModifier) {
    Column(modifier = root.padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(R.drawable.ic_widget_computer, muted, 12)
            Gap(5)
            Text(context.getString(R.string.widget_quick_connect_label), style = text(muted, 11, FontWeight.Medium))
        }
        Spacer(GlanceModifier.height(8.dp))
        if (snapshot.computers.isEmpty()) {
            Text(context.getString(R.string.widget_quick_connect_empty), style = text(muted, 12))
        } else {
            snapshot.computers.take(rows).forEach { computer ->
                ComputerRow(context, computer, snapshot.presence(computer.id))
                Spacer(GlanceModifier.height(6.dp))
            }
        }
    }
}

@Composable
private fun ComputerRow(context: Context, computer: KnownComputer, presence: ComputerPresence) {
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .background(ImageProvider(R.drawable.widget_row))
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .clickable(openLink(context, WidgetLink.connect(computer.id))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(R.drawable.ic_widget_computer, ink, 14)
        Gap(8)
        Text(computer.name, style = text(ink, 13, FontWeight.Medium), maxLines = 1, modifier = GlanceModifier.defaultWeight())
        when (presence) {
            ComputerPresence.CONNECTED -> Dot(R.drawable.widget_dot_active)
            ComputerPresence.ONLINE -> Dot(R.drawable.widget_dot_dim)
            ComputerPresence.OFFLINE -> Icon(R.drawable.ic_widget_chevron, faint, 12)
        }
    }
}

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
import pl.dmq.peering.R

/** Only the chats asking for an answer; a tap opens the app on that chat. */
class WaitingWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, WIDE, TALL))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val waiting = WidgetStore(context).agents().needingYou
        provideContent { WaitingContent(waiting) }
    }

    private companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
        val TALL = DpSize(250.dp, 200.dp)
    }
}

@Composable
private fun WaitingContent(waiting: List<AgentChatEntry>) {
    val context = LocalContext.current
    val size = LocalSize.current
    val top = waiting.firstOrNull()
    val root = GlanceModifier.fillMaxSize().appWidgetBackground().background(ImageProvider(R.drawable.widget_container)).padding(12.dp)
    if (size.width < 200.dp) {
        val link = top?.let { WidgetLink.chat(it.id, it.hostId) } ?: WidgetLink.connect(null)
        Column(modifier = root.clickable(openLink(context, link))) {
            Header(context, waiting.size)
            Spacer(GlanceModifier.defaultWeight())
            Text(waiting.size.toString(), style = text(if (top == null) muted else stateBlue, 30, FontWeight.Bold))
            Text(top?.title ?: context.getString(R.string.widget_waiting_none), style = text(muted, 11), maxLines = 2)
        }
    } else {
        val rows = if (size.height >= 180.dp) 4 else 2
        Column(modifier = root) {
            Header(context, waiting.size)
            Spacer(GlanceModifier.height(8.dp))
            if (top == null) {
                Text(context.getString(R.string.widget_waiting_empty), style = text(muted, 12))
            } else {
                waiting.take(rows).forEach { chat ->
                    WaitingRow(context, chat)
                    Spacer(GlanceModifier.height(6.dp))
                }
            }
        }
    }
}

@Composable
private fun Header(context: Context, count: Int) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(R.drawable.ic_widget_bell, if (count > 0) stateBlue else muted, 12)
        Gap(5)
        Text(context.getString(R.string.widget_waiting_label), style = text(muted, 11, FontWeight.Medium))
    }
}

@Composable
private fun WaitingRow(context: Context, chat: AgentChatEntry) {
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .background(ImageProvider(R.drawable.widget_row))
            .padding(horizontal = 10.dp, vertical = 7.dp)
            .clickable(openLink(context, WidgetLink.chat(chat.id, chat.hostId))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Dot(R.drawable.widget_dot_active)
        Gap(9)
        Text(chat.title, style = text(ink, 13, FontWeight.Medium), maxLines = 1, modifier = GlanceModifier.defaultWeight())
        if (chat.folder.isNotEmpty()) {
            Gap(5)
            Text(chat.folder, style = text(muted, 10), maxLines = 1)
        }
    }
}

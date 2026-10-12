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
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.unit.ColorProvider
import pl.dmq.peering.R

/** The running and recent agent chats with their state; a tap opens the app on the chat's computer. */
class AgentsWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, WIDE, TALL))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetStore(context).agents()
        val nowSeconds = System.currentTimeMillis() / MILLIS_PER_SECOND
        provideContent { AgentsContent(snapshot, snapshot.isStale(nowSeconds)) }
    }

    private companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
        val TALL = DpSize(250.dp, 200.dp)
        const val MILLIS_PER_SECOND = 1_000L
    }
}

@Composable
private fun AgentsContent(snapshot: AgentsSnapshot, stale: Boolean) {
    val context = LocalContext.current
    val size = LocalSize.current
    val top = snapshot.chats.firstOrNull()
    val root = GlanceModifier.fillMaxSize().appWidgetBackground().background(ImageProvider(R.drawable.widget_container)).padding(12.dp)
    if (size.width < 200.dp) {
        val link = top?.let { WidgetLink.chat(it.id, it.hostId) } ?: WidgetLink.connect(null)
        Column(modifier = root.clickable(openLink(context, link))) {
            Header(context, snapshot)
            Spacer(GlanceModifier.defaultWeight())
            if (top == null) EmptyText(context) else SmallChat(context, top, stale)
        }
    } else {
        val rows = if (size.height >= 180.dp) 4 else 2
        Column(modifier = root) {
            Header(context, snapshot)
            Spacer(GlanceModifier.height(8.dp))
            if (top == null) {
                EmptyText(context)
            } else {
                snapshot.chats.take(rows).forEach { chat ->
                    ChatRow(context, chat, stale)
                    Spacer(GlanceModifier.height(6.dp))
                }
            }
        }
    }
}

@Composable
private fun Header(context: Context, snapshot: AgentsSnapshot) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(R.drawable.ic_widget_agents, muted, 12)
        Gap(5)
        Text(context.getString(R.string.widget_agents_label), style = text(muted, 11, FontWeight.Medium))
        Spacer(GlanceModifier.defaultWeight())
        when {
            snapshot.waiting > 0 -> Text(context.getString(R.string.widget_agents_waiting, snapshot.waiting), style = text(stateBlue, 11, FontWeight.Medium))
            snapshot.working > 0 -> Text(context.getString(R.string.widget_agents_working, snapshot.working), style = text(muted, 11))
        }
    }
}

@Composable
private fun EmptyText(context: Context) {
    Column {
        Text(context.getString(R.string.widget_agents_empty_title), style = text(ink, 15, FontWeight.Bold))
        Text(context.getString(R.string.widget_agents_empty_detail), style = text(muted, 11))
    }
}

@Composable
private fun SmallChat(context: Context, chat: AgentChatEntry, stale: Boolean) {
    Text(chat.title, style = text(ink, 15, FontWeight.Bold), maxLines = 1)
    Text(statusLine(context, chat, stale), style = text(statusColor(chat, stale), 11), maxLines = 2)
}

@Composable
private fun ChatRow(context: Context, chat: AgentChatEntry, stale: Boolean) {
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .background(ImageProvider(R.drawable.widget_row))
            .padding(horizontal = 10.dp, vertical = 7.dp)
            .clickable(openLink(context, WidgetLink.chat(chat.id, chat.hostId))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = GlanceModifier.size(26.dp).background(ImageProvider(R.drawable.widget_tile)),
            contentAlignment = Alignment.Center,
        ) { Icon(R.drawable.ic_widget_agents, ink, 12) }
        Gap(9)
        Column(modifier = GlanceModifier.defaultWeight()) {
            Row {
                Text(chat.title, style = text(ink, 13, FontWeight.Medium), maxLines = 1, modifier = GlanceModifier.defaultWeight())
                if (chat.folder.isNotEmpty()) {
                    Gap(5)
                    Text(chat.folder, style = text(muted, 10), maxLines = 1)
                }
            }
            Text(statusLine(context, chat, stale), style = text(statusColor(chat, stale), 11), maxLines = 1)
        }
        Gap(6)
        Dot(dotFor(chat.tone))
    }
}

private fun statusLine(context: Context, chat: AgentChatEntry, stale: Boolean): String = when {
    stale -> context.getString(R.string.widget_agent_stale)
    chat.tone == AgentChatTone.NEEDS_YOU -> context.getString(R.string.widget_agent_waiting)
    chat.tone == AgentChatTone.WORKING -> context.getString(R.string.widget_agent_working)
    chat.tone == AgentChatTone.FAILED -> context.getString(R.string.widget_agent_failed)
    else -> context.getString(R.string.widget_agent_finished)
}

private fun statusColor(chat: AgentChatEntry, stale: Boolean): ColorProvider = when {
    stale -> muted
    chat.tone == AgentChatTone.NEEDS_YOU -> stateBlue
    chat.tone == AgentChatTone.FAILED -> failed
    else -> muted
}

private fun dotFor(tone: AgentChatTone): Int = when (tone) {
    AgentChatTone.NEEDS_YOU -> R.drawable.widget_dot_active
    AgentChatTone.WORKING -> R.drawable.widget_dot_dim
    AgentChatTone.FAILED -> R.drawable.widget_dot_failed
    AgentChatTone.FINISHED -> R.drawable.widget_dot_faint
}

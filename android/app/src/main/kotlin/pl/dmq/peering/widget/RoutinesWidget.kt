package pl.dmq.peering.widget

import android.content.Context
import android.text.format.DateUtils
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

/** Scheduled agent runs: which is running now, how the last one ended, and when the next starts. */
class RoutinesWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, WIDE, TALL))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetStore(context).routines()
        provideContent { RoutinesContent(snapshot) }
    }

    private companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
        val TALL = DpSize(250.dp, 200.dp)
    }
}

@Composable
private fun RoutinesContent(snapshot: RoutinesSnapshot) {
    val context = LocalContext.current
    val size = LocalSize.current
    val top = snapshot.routines.firstOrNull()
    val root = GlanceModifier.fillMaxSize().appWidgetBackground().background(ImageProvider(R.drawable.widget_container)).padding(12.dp)
    if (size.width < 200.dp) {
        Column(modifier = root.clickable(openLink(context, WidgetLink.connect(null)))) {
            Header(context)
            Spacer(GlanceModifier.defaultWeight())
            if (top == null) {
                Text(context.getString(R.string.widget_routines_none), style = text(muted, 11))
            } else {
                Text(top.name, style = text(ink, 15, FontWeight.Bold), maxLines = 1)
                Text(status(context, top), style = text(toneColor(top), 11), maxLines = 2)
            }
        }
    } else {
        val rows = if (size.height >= 180.dp) 4 else 2
        Column(modifier = root.clickable(openLink(context, WidgetLink.connect(null)))) {
            Header(context)
            Spacer(GlanceModifier.height(8.dp))
            if (top == null) {
                Text(context.getString(R.string.widget_routines_empty), style = text(muted, 12))
            } else {
                snapshot.routines.take(rows).forEach { routine ->
                    RoutineRow(context, routine)
                    Spacer(GlanceModifier.height(6.dp))
                }
            }
        }
    }
}

@Composable
private fun Header(context: Context) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(R.drawable.ic_widget_routines, muted, 12)
        Gap(5)
        Text(context.getString(R.string.widget_routines_label), style = text(muted, 11, FontWeight.Medium))
    }
}

@Composable
private fun RoutineRow(context: Context, routine: RoutineEntry) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().background(ImageProvider(R.drawable.widget_row)).padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Dot(if (routine.tone == RoutineTone.RUNNING) R.drawable.widget_dot_active else R.drawable.widget_dot_faint)
        Gap(9)
        Text(routine.name, style = text(ink, 13, FontWeight.Medium), maxLines = 1, modifier = GlanceModifier.defaultWeight())
        Gap(6)
        Text(status(context, routine), style = text(toneColor(routine), 11), maxLines = 1)
    }
}

private fun toneColor(routine: RoutineEntry) = when {
    !routine.isEnabled -> muted
    routine.tone == RoutineTone.RUNNING -> stateBlue
    routine.tone == RoutineTone.FAILED || routine.tone == RoutineTone.SKIPPED -> failed
    else -> muted
}

private fun status(context: Context, routine: RoutineEntry): String {
    if (!routine.isEnabled) return context.getString(R.string.widget_routine_off)
    return when (routine.tone) {
        RoutineTone.RUNNING -> context.getString(R.string.widget_routine_running)
        RoutineTone.FAILED -> context.getString(R.string.widget_routine_failed)
        RoutineTone.STOPPED -> context.getString(R.string.widget_routine_stopped)
        RoutineTone.SKIPPED -> context.getString(R.string.widget_routine_skipped)
        RoutineTone.SUCCEEDED, RoutineTone.NEVER_RUN -> {
            val next = routine.nextRunAtMillis
            when {
                next != null -> context.getString(
                    R.string.widget_routine_next,
                    DateUtils.getRelativeTimeSpanString(next, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS),
                )
                routine.tone == RoutineTone.SUCCEEDED -> context.getString(R.string.widget_routine_done)
                else -> context.getString(R.string.widget_routine_not_run)
            }
        }
    }
}

package pl.dmq.peering.feature.agents.routines

import android.app.TimePickerDialog
import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.routines.AgentRoutineDraft
import pl.dmq.peering.session.agent.routines.AgentRoutineValidation
import pl.dmq.peering.session.agent.routines.RoutineCadence
import pl.dmq.peering.session.agent.routines.RoutineIntervalUnit
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlPicker
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.kit.TonalButton
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import java.time.temporal.WeekFields
import java.util.Locale

private val HOUR_CHOICES = listOf(1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168)
private val MINUTE_CHOICES = listOf(15, 30, 45, 60, 90, 120, 180, 240)

/** When a routine runs: every so often, or at a time on chosen days. */
@Composable
internal fun RoutineScheduleCard(draft: AgentRoutineDraft, presenter: RoutinesPresenter) {
    ControlsCard(stringResource(R.string.routines_card_schedule)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CadenceButton(R.string.routines_at_a_time, draft.cadence == RoutineCadence.DAILY, Modifier.weight(1f)) {
                presenter.setCadence(RoutineCadence.DAILY)
            }
            CadenceButton(R.string.routines_every_so_often, draft.cadence == RoutineCadence.INTERVAL, Modifier.weight(1f)) {
                presenter.setCadence(RoutineCadence.INTERVAL)
            }
        }
        when (draft.cadence) {
            RoutineCadence.INTERVAL -> IntervalRows(draft, presenter)
            RoutineCadence.DAILY -> DailyRows(draft, presenter)
        }
    }
}

@Composable
private fun CadenceButton(title: Int, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val label: @Composable () -> Unit = { Text(stringResource(title), style = PeeringText.captionSemibold) }
    if (selected) {
        TonalButton(onClick, modifier.semantics { this.selected = true }) { label() }
    } else {
        QuietButton(onClick, modifier) { label() }
    }
}

@Composable
private fun IntervalRows(draft: AgentRoutineDraft, presenter: RoutinesPresenter) {
    val choices = if (draft.intervalUnit == RoutineIntervalUnit.HOURS) HOUR_CHOICES else MINUTE_CHOICES.filter { it >= AgentRoutineValidation.MINIMUM_INTERVAL_MINUTES }
    ControlPicker(
        title = stringResource(R.string.routines_every_label),
        icon = AppIcons.clockAlert,
        selected = draft.intervalValue,
        options = if (draft.intervalValue in choices) choices else (choices + draft.intervalValue).sorted(),
        optionTitle = { it.toString() },
        onSelect = { value -> presenter.change { it.copy(intervalValue = value) } },
    )
    ControlPicker(
        title = stringResource(R.string.routines_unit),
        icon = AppIcons.tune,
        selected = draft.intervalUnit,
        options = RoutineIntervalUnit.entries,
        optionTitle = { stringResource(if (it == RoutineIntervalUnit.HOURS) R.string.routines_unit_hours else R.string.routines_unit_minutes) },
        onSelect = presenter::setUnit,
    )
}

@Composable
private fun DailyRows(draft: AgentRoutineDraft, presenter: RoutinesPresenter) {
    val context = LocalContext.current
    ControlLink(
        title = stringResource(R.string.routines_time),
        icon = AppIcons.clockAlert,
        onClick = {
            TimePickerDialog(
                context,
                { _, hour, minute -> presenter.change { it.copy(hour = hour, minute = minute) } },
                draft.hour,
                draft.minute,
                DateFormat.is24HourFormat(context),
            ).show()
        },
        detail = clockText(draft.hour, draft.minute),
    )
    val locale = Locale.getDefault()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        RoutineWeekdays.ordered(WeekFields.of(locale).firstDayOfWeek).forEach { day ->
            DayChip(
                label = RoutineWeekdays.narrowName(day, locale),
                description = RoutineWeekdays.fullName(day, locale),
                on = day in draft.weekdays,
                modifier = Modifier.weight(1f),
            ) { presenter.change { it.toggling(day) } }
        }
    }
}

@Composable
private fun DayChip(label: String, description: String, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val shape = CircleShape
    Box(
        modifier
            .height(32.dp)
            .clip(shape)
            .then(if (on) Modifier.background(PeeringColors.selectedIndicator) else Modifier.border(1.dp, PeeringColors.hairline, shape))
            .tappable(onClick, role = Role.Checkbox)
            .semantics {
                selected = on
                contentDescription = description
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = PeeringText.captionSemibold, color = if (on) PeeringColors.ink else PeeringColors.muted)
    }
}

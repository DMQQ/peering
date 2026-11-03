import PeeringKit
import SwiftUI

/// When a routine runs: every so often, or at a time on chosen days.
struct AgentRoutineScheduleCard: View {
    @Binding var draft: AgentRoutineDraft

    var body: some View {
        Controls.card(String(localized: "Schedule")) {
            Picker(String(localized: "Repeat"), selection: $draft.cadence) {
                Text("At a time").tag(AgentRoutineDraft.Cadence.daily)
                Text("Every so often").tag(AgentRoutineDraft.Cadence.interval)
            }
            .pickerStyle(.segmented)
            switch draft.cadence {
            case .interval: interval
            case .daily: daily
            }
        }
    }

    private var interval: some View {
        HStack(spacing: 11) {
            Stepper(value: $draft.intervalValue, in: draft.intervalUnit == .hours ? 1...168 : 15...600) {
                Text(verbatim: AgentRoutineText.schedule(draft.schedule))
                    .font(.subheadline.weight(.medium))
            }
            Picker(String(localized: "Unit"), selection: unitBinding) {
                Text("Hours").tag(AgentRoutineDraft.IntervalUnit.hours)
                Text("Minutes").tag(AgentRoutineDraft.IntervalUnit.minutes)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.white.opacity(0.72))
        }
    }

    private var unitBinding: Binding<AgentRoutineDraft.IntervalUnit> {
        Binding(get: { draft.intervalUnit }, set: { unit in
            draft.intervalUnit = unit
            draft.intervalValue = unit == .hours ? 1 : 30
        })
    }

    private var daily: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker(String(localized: "Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(orderedWeekdays, id: \.self) { day in dayChip(day) }
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.hour = parts.hour ?? 9
            draft.minute = parts.minute ?? 0
        })
    }

    /// Starting from the locale's first day of the week.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func dayChip(_ day: Int) -> some View {
        let isOn = draft.weekdays.contains(day)
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return Button {
            if isOn { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
        } label: {
            Text(verbatim: symbols.indices.contains(day - 1) ? symbols[day - 1] : "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? ColorPalette.ink : .white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background { if isOn { Circle().fill(ColorPalette.selectedFill) } }
                .overlay { if !isOn { Circle().strokeBorder(.white.opacity(0.14)) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Calendar.current.weekdaySymbols[day - 1]))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

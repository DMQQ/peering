import Foundation
import RemoteCore
import SwiftUI

/// Wakes the Mac again when the window opens.
struct WakeScheduleRow: View {
    @Environment(HostModel.self) private var model

    @State private var asksAboutReplacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "alarm")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(
                        model.wakeScheduleHour != nil ? HostPalette.ink : HostPalette.muted
                    )
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake it up every day")
                        .font(.subheadline.weight(.medium))
                    Text(caption)
                        .hostCaption()
                }

                Spacer(minLength: 12)

                if model.wakeScheduleBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26)
                } else {
                    Toggle("", isOn: Binding(
                        get: { model.wakeScheduleHour != nil },
                        set: apply
                    ))
                    .hostSwitch()
                }
            }

            if let hour = model.wakeScheduleHour {
                HStack(spacing: 6) {
                    Text("Wake at")
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                    Picker("", selection: Binding(
                        get: { hour },
                        set: { chosen in Task { await model.setWakeSchedule(hour: chosen) } }
                    )) {
                        ForEach(0..<24, id: \.self) { value in
                            Text(String(format: "%02d:00", value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 88)
                }
                .padding(.leading, 38)
            }

            if let failure = model.wakeScheduleFailure {
                Text(failure)
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }

            // **The reading that defeats everything else in this pane.** A Mac told never to
            // idle-sleep does not sleep when the last assertion lets go, so the schedule would run,
            // report success, and change nothing anybody could see. It is not Peering's setting and
            // Peering does not undo it, which is exactly why it has to be said out loud.
            if model.idleSleepMinutes == 0 {
                Text("This Mac is set never to sleep on its own. That is a system setting rather than one of the switches here (Energy Saver, \"Prevent automatic sleeping when the display is off\"), and while it is on, nothing in this app can let this Mac sleep.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }

            if !model.otherScheduledEvents.isEmpty {
                Text("Already scheduled on this Mac: \(model.otherScheduledEvents.joined(separator: " · "))")
                    .hostCaption()
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task { await model.refreshPowerReadings() }
        .alert("Replace what is already scheduled?", isPresented: $asksAboutReplacing) {
            Button("Replace it") {
                Task { await model.setWakeSchedule(hour: model.keepAwakeStartHour) }
            }
            Button("Leave it alone", role: .cancel) {}
        } message: {
            Text("""
                macOS allows one repeating power schedule, and this Mac already has one:

                \(model.otherScheduledEvents.joined(separator: "\n"))

                Turning this on replaces it.
                """)
        }
    }

    private func apply(_ on: Bool) {
        guard on else {
            Task { await model.setWakeSchedule(hour: nil) }
            return
        }
        // One repeating pair is all `pmset` holds, so this replaces whatever is there. Asked
        // rather than done, because overwriting somebody's own schedule without saying so is the
        // kind of thing that is only discovered later.
        guard model.otherScheduledEvents.isEmpty else {
            asksAboutReplacing = true
            return
        }
        Task { await model.setWakeSchedule(hour: model.keepAwakeStartHour) }
    }

    private var caption: String {
        guard let hour = model.wakeScheduleHour else {
            return String(localized: "Off. Once this Mac has slept, nothing can reach it until something wakes it, and nothing here will.")
        }
        return "macOS wakes this Mac at \(String(format: "%02d:00", hour)) every day. It works with nothing running and nothing on the network. On battery it may not fire."
    }
}

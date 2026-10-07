import Foundation
import RemoteCore
import SwiftUI

/// The window the keep-awake switches are held inside.
struct KeepAwakeScheduleRow: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(
                        model.keepAwakeScheduleEnabled ? HostPalette.ink : HostPalette.muted
                    )
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it awake only between these hours")
                        .font(.subheadline.weight(.medium))
                    Text(caption)
                        .hostCaption()
                }

                Spacer(minLength: 12)

                Toggle("", isOn: Binding(
                    get: { model.keepAwakeScheduleEnabled },
                    set: { model.setKeepAwakeSchedule(enabled: $0) }
                ))
                .hostSwitch()
            }

            if model.keepAwakeScheduleEnabled {
                HStack(spacing: 12) {
                    hourPicker("From", hour: model.keepAwakeStartHour) {
                        model.setKeepAwakeHours(start: $0, end: model.keepAwakeEndHour)
                    }
                    hourPicker("To", hour: model.keepAwakeEndHour) {
                        model.setKeepAwakeHours(start: model.keepAwakeStartHour, end: $0)
                    }
                    if model.keepAwakeEndHour < model.keepAwakeStartHour {
                        Text("overnight")
                            .font(.caption)
                            .foregroundStyle(HostPalette.muted)
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func hourPicker(
        _ label: String, hour: Int, set: @escaping @MainActor @Sendable (Int) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(HostPalette.muted)
            Picker("", selection: Binding(get: { hour }, set: set)) {
                ForEach(0..<24, id: \.self) { value in
                    Text(String(format: "%02d:00", value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 88)
        }
    }

    /// What the window does, and then what it cannot do.
    private var caption: String {
        guard model.keepAwakeScheduleEnabled else {
            return String(localized: "Off. The switches above keep this Mac awake all day and all night.")
        }
        let start = String(format: "%02d:00", model.keepAwakeStartHour)
        let end = String(format: "%02d:00", model.keepAwakeEndHour)
        let sentence = String(localized: "This Mac stays awake from \(start) to \(end), and sleeps the rest of the time unless you are connected to it.")
        if model.keepRunningWithLidClosed, model.lidCloseRuleInstalled != true {
            return sentence + String(localized: " The lid-close switch below needs its administrator rule before this can release it.")
        }
        return sentence
    }
}

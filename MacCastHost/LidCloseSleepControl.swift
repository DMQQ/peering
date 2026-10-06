import Foundation
import RemoteCore
import SwiftUI

enum LidCloseSleepControl {
    enum Outcome: Sendable, Equatable {
        case done
        case cancelled
        /// It ran and did not work, with a sentence for the window.
        case failed(String)
    }

    static var invokingUserName: String { NSUserName() }

    // MARK: - Reading

    /// What `pmset -g` says about sleeping on a closed lid.
    static func sleepDisabledState() async -> LidCloseSleep.SleepDisabledState {
        await offTheMainThread {
            LidCloseSleep.sleepDisabledState(inPMSetOutput: run(LidCloseSleep.pmsetPath, ["-g"]).out)
        }
    }

    /// What `pmset -g batt` says about the power source and the charge.
    static func batteryState() async -> LidCloseSleep.BatteryState {
        await offTheMainThread {
            LidCloseSleep.batteryState(
                inPMBattOutput: run(LidCloseSleep.pmsetPath, ["-g", "batt"]).out
            )
        }
    }

    /// Whether the drop-in is in place, as `sudo` reads it.
    static func ruleGrants() async -> LidCloseSleep.Grants? {
        await offTheMainThread {
            let result = run("/usr/bin/sudo", ["-n", "-l"])
            guard result.status == 0 else { return nil }
            return LidCloseSleep.grants(inSudoListing: result.out)
        }
    }

    // MARK: - Acting

    /// Turns the setting on or off without a prompt.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) async -> Outcome {
        await offTheMainThread { applySleepDisabled(disabled) }
    }

    /// The same thing, with the system's authentication dialog instead of the rule.
    static func setSleepDisabledAskingForAdmin(_ disabled: Bool, prompt: String) async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.command(disabled: disabled),
            prompt: prompt
        )
    }

    /// Installs the drop-in, taking administrator rights once.
    static func installRule(user: String) async -> Outcome {
        let script: String
        do {
            script = try LidCloseSleep.installScript(user: user)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        return await runAsAdministrator(
            shellScript: script,
            prompt: String(localized: "Peering needs to install a rule that lets it stop this Mac sleeping with the lid closed. The rule allows two commands: pmset -a disablesleep 1, and pmset -a disablesleep 0.")
        )
    }

    static func removeRule() async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.removeScript(),
            prompt: String(localized: "Peering will remove its administrator rule and let this Mac sleep normally again.")
        )
    }

    /// Turns the setting off from the quit path, where nothing can be waited for.
    @discardableResult
    static func restoreSleepSilently() -> Outcome {
        applySleepDisabled(false)
    }

    // MARK: - Running things

    static func setWakeSchedule(hour: Int) async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.wakeCommand(hour: hour),
            prompt: String(localized: "Peering will wake this Mac at \(LidCloseSleep.hourString(hour).prefix(5)) every day.")
        )
    }

    static func clearWakeSchedule() async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.cancelScheduleCommand,
            prompt: String(localized: "Peering will take away the daily wake it set for this Mac.")
        )
    }

    static func scheduledEvents() async -> [String] {
        await offTheMainThread {
            LidCloseSleep.otherScheduledEvents(
                inSchedOutput: run(LidCloseSleep.pmsetPath, ["-g", "sched"]).out
            )
        }
    }

    /// The system's own idle-sleep timer, in minutes. `0` means never.
    static func idleSleepMinutes() async -> Int? {
        await offTheMainThread {
            LidCloseSleep.idleSleepMinutes(inPMSetOutput: run(LidCloseSleep.pmsetPath, ["-g"]).out)
        }
    }

    private static func applySleepDisabled(_ disabled: Bool) -> Outcome {
        let result = run(
            "/usr/bin/sudo",
            ["-n", LidCloseSleep.pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]
        )
        guard result.status != 0 else { return .done }
        let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? String(localized: "Could not change the sleep setting (sudo exited \(result.status)).") : message)
    }

    /// Runs one shell script as root, through the system's own authentication dialog.
    private static func runAsAdministrator(shellScript: String, prompt: String) async -> Outcome {
        let script = LidCloseSleep.administratorScript(shellScript: shellScript, prompt: prompt)
        return await offTheMainThread {
            let result = run("/usr/bin/osascript", ["-e", script])
            guard result.status != 0 else { return .done }
            let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
                return .cancelled
            }
            return .failed(
                message.isEmpty
                    ? String(localized: "The administrator prompt did not finish (osascript exited \(result.status)).")
                    : message
            )
        }
    }

    struct Output: Sendable {
        var status: Int32
        var out: String
        var err: String
    }

    /// Runs one process to completion and collects what it said.
    static func run(_ executable: String, _ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Output(status: -1, out: "", err: String(localized: "Could not run \(executable): \(error.localizedDescription)"))
        }
        // **Both pipes are drained at the same time, not one after the other.** Reading `out` to
        // the end first looks like draining and is not: a child that fills the stderr pipe blocks
        // on the write while this side waits for stdout that will never come, and the shape that
        // deadlock takes here is the worst one available, an authentication dialog on screen with
        let errBox = PipeOutput()
        let errFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errFinished.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errFinished.wait()
        let errData = errBox.data
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs `work` somewhere that is not the main thread.
    private static func offTheMainThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
}

/// One pipe's worth of bytes, carried across a thread boundary exactly once.
private final class PipeOutput: @unchecked Sendable {
    var data = Data()
}

/// The row for "keep this Mac awake": one power assertion, held for as long as the host runs.
struct KeepAwakeRow: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.preventLidCloseSleep ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keep Mac awake")
                    .font(.subheadline.weight(.medium))
                // Says which of the two switches this is, because the second one is about the same
                // subject and costs something: this holds an idle-sleep assertion, which needs no
                // permission and is released when Peering quits, and it does not keep a closed Mac
                // running. The row below does.
                Text("Keeps this Mac awake on its own: no idle sleep, no display sleep, and no permission prompt. It does not survive the lid being shut, and the row about the lid is the one that does. Lifted automatically when Peering quits.")
                    .hostCaption()

                // **The line that says the switch is on and nothing is happening.** Without it the
                // only way to find out whether this Mac is being held was to guess, which is what a
                // switch reading "on" over a sleeping Mac invites. See
                // ``HostModel/keepAwakeWithheldExplanation``.
                if let withheld = model.keepAwakeWithheldExplanation {
                    Text(withheld)
                        .font(.caption)
                        .foregroundStyle(HostPalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { model.preventLidCloseSleep },
                set: { model.setPreventLidCloseSleep($0) }
            ))
            .hostSwitch()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

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

/// The row for "keep running with the lid closed", and the explanation it owes before it does
/// anything.
struct LidCloseSleepRow: View {
    @Environment(HostModel.self) private var model
    @State private var explaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(model.keepRunningWithLidClosed ? HostPalette.ink : HostPalette.muted)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep running with the lid closed")
                        .font(.subheadline.weight(.medium))
                    Text("Survives the lid being shut, which the switch above does not. macOS only offers this through pmset, so it needs your administrator password once, and while it is on the Mac does not sleep at all: leave it open to the air rather than shut in a bag. Undone when Peering quits, and repaired at the next launch if it is force quit instead.")
                        .hostCaption()
                }

                Spacer(minLength: 12)

                // A spinner in place of the switch while the password dialog is up, because the
                // switch cannot move until there is an answer and a control that ignores a click
                // reads as broken.
                if model.lidCloseBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26)
                } else {
                    Toggle("", isOn: Binding(get: { model.keepRunningWithLidClosed }, set: apply))
                        .hostSwitch()
                }
            }

            if let failure = model.lidCloseFailure {
                Text(failure)
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }

            // **The switch and the machine, when they disagree.** This is the state the entire
            // recovery path exists for and it used to be invisible: a rule removed by hand, or a
            // crash between the write and the marker, left a switch reading "on" over a Mac that
            // slept the moment the lid shut. The app cannot promise a Mac stays up; it can promise
            if model.keepRunningWithLidClosed, !model.keepAwakeWithheld,
               model.lidCloseSystemState == .off {
                Text("Switched on, but this Mac is not doing it: pmset reports the setting as off. Switch this off and on again to put it back.")
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }

            if model.lidCloseRuleInstalled == true {
                HStack(spacing: 6) {
                    Text("The administrator rule covers only \(LidCloseSleep.command(disabled: true)) and \(LidCloseSleep.command(disabled: false)).")
                        .hostCaption()

                    Button {
                        Task { await model.removeLidCloseRule() }
                    } label: {
                        Text("Remove it").underline()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .help("Deletes /etc/sudoers.d/peering-sleep and lets this Mac sleep normally again, in one administrator prompt.")
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .alert("Keep running with the lid closed?", isPresented: $explaining) {
            Button("Install the rule") { Task { await model.enableLidCloseSleep() } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(explanation)
        }
        .task { await model.checkLidCloseSleepRule() }
    }

    /// The price, before anything is asked for.
    private var explanation: String {
        """
        macOS keeps a Mac awake with its lid shut only through pmset, and that needs administrator \
        rights. Peering will ask for your password once and leave a rule at \
        /etc/sudoers.d/peering-sleep.

        The rule allows exactly two commands, run as root: \(LidCloseSleep.command(disabled: true)) \
        and \(LidCloseSleep.command(disabled: false)). Nothing else becomes possible, and removing \
        the rule takes it all back.

        While it is on, the Mac does not sleep at all, on battery included, so leave it open to the \
        air rather than shut in a bag. Peering turns it back off when it quits and when you switch \
        this off.
        """
    }

    /// The switch asks first or acts, depending on whether the price has been paid before.
    private func apply(_ wanted: Bool) {
        if wanted, model.lidCloseRuleInstalled != true {
            explaining = true
        } else {
            Task { await model.setKeepRunningWithLidClosed(wanted) }
        }
    }
}

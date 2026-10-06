import Foundation
import RemoteCore
import SwiftUI

/// The privileged half of "keep running with the lid closed": the administrator prompt, the two
/// commands it buys, and the reading of what the machine currently does.
///
/// **Why this is a type of its own rather than more of ``HostModel``.** Every function here spawns
/// a process, and two of them can put the system's authentication dialog on screen, which means
/// each one blocks until something outside this app has finished. That is a property worth
/// containing: the model decides what should happen, this decides how to ask for it, and the parts
/// of both that are pure live in ``LidCloseSleep``, where they have tests.
enum LidCloseSleepControl {
    /// How a privileged action ended, in the three ways it can.
    enum Outcome: Sendable, Equatable {
        /// It ran and it worked.
        case done
        /// The user dismissed the authentication dialog. Not a failure, and not a change of state:
        /// the row puts its switch back and says nothing about it.
        case cancelled
        /// It ran and did not work, with a sentence for the window.
        case failed(String)
    }

    /// The name the rule is written for: the account running this app, not every account.
    ///
    /// It could be written for `%admin` and cover whoever is at the machine next, which is both
    /// wider than the promise the window makes and narrower than it looks, since it would stop
    /// working the day the account is taken out of that group.
    static var invokingUserName: String { NSUserName() }

    // MARK: - Reading

    /// What `pmset -g` says about sleeping on a closed lid.
    ///
    /// Asked of a process because there is no API for this setting: it is a `pmset` value,
    /// `SleepDisabled` is the name it prints under, and the tool that sets it is the only thing
    /// whose answer is certainly about the same setting.
    static func sleepDisabledState() async -> LidCloseSleep.SleepDisabledState {
        await offTheMainThread {
            LidCloseSleep.sleepDisabledState(inPMSetOutput: run(LidCloseSleep.pmsetPath, ["-g"]).out)
        }
    }

    /// What `pmset -g batt` says about the power source and the charge.
    ///
    /// Asked of `pmset` rather than of IOKit for the reason the rest of this file asks `pmset`: one
    /// tool, one answer, and the same one the feature's own setting comes from. It is read once a
    /// minute and only while the Mac is being kept up with its lid shut, so the cost is a process
    /// per minute in the one state where a flat battery is possible.
    static func batteryState() async -> LidCloseSleep.BatteryState {
        await offTheMainThread {
            LidCloseSleep.batteryState(
                inPMBattOutput: run(LidCloseSleep.pmsetPath, ["-g", "batt"]).out
            )
        }
    }

    /// Whether the drop-in is in place, as `sudo` reads it.
    ///
    /// `-n` is what makes this safe to run unasked: it turns "may I" into a question with no
    /// dialog attached, so a Mac without the rule answers no in a few milliseconds rather than
    /// putting a password prompt up at launch. The listing is read rather than the file because
    /// the file cannot be read without being root, and because the answer that matters is what
    /// `sudo` will do rather than what is on disk.
    ///
    /// `nil` when `sudo` would not list at all, which is a different answer from "not installed":
    /// it means this could not be established, and the row treats it as not knowing.
    static func ruleGrants() async -> LidCloseSleep.Grants? {
        await offTheMainThread {
            let result = run("/usr/bin/sudo", ["-n", "-l"])
            guard result.status == 0 else { return nil }
            return LidCloseSleep.grants(inSudoListing: result.out)
        }
    }

    // MARK: - Acting

    /// Turns the setting on or off without a prompt.
    ///
    /// Only ever works once the rule is in place, and `sudo`'s own refusal is not the sentence to
    /// show: "a password is required" is true and useless, and the caller has a better one, which
    /// is that the rule is missing and has to be installed again.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) async -> Outcome {
        await offTheMainThread { applySleepDisabled(disabled) }
    }

    /// The same thing, with the system's authentication dialog instead of the rule.
    ///
    /// The way out of the one state that would otherwise have none: a Mac whose sleep is disabled
    /// and whose rule has been taken away cannot be put back by the silent path, and a switch that
    /// refuses to turn off is worse than one password prompt.
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

    /// Takes the rule away and lets the Mac sleep again, in one prompt.
    static func removeRule() async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.removeScript(),
            prompt: String(localized: "Peering will remove its administrator rule and let this Mac sleep normally again.")
        )
    }

    /// Turns the setting off from the quit path, where nothing can be waited for.
    ///
    /// Synchronous on purpose: the process is going away, so there is no later in which to finish
    /// an `await`. `-n` is also what makes it safe here, because quitting must never put a
    /// password prompt on screen: it works or it fails, both in milliseconds.
    @discardableResult
    static func restoreSleepSilently() -> Outcome {
        applySleepDisabled(false)
    }

    // MARK: - Running things

    /// The silent `pmset` call that both of the without-a-prompt paths go through.
    /// Sets the repeating daily wake, through the system's own password dialog.
    ///
    /// **The prompting path rather than the silent rule, and that is the design.** The rule exists
    /// for the one setting that gets flipped often, which is lid-close sleep. A wake time is set
    /// once and changed rarely, so widening a standing grant to cover `pmset repeat` would buy
    /// nothing and hand away reach this file has taken trouble to keep narrow.
    static func setWakeSchedule(hour: Int) async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.wakeCommand(hour: hour),
            prompt: String(localized: "Peering will wake this Mac at \(LidCloseSleep.hourString(hour).prefix(5)) every day.")
        )
    }

    /// Takes the repeating schedule away, through the same dialog.
    static func clearWakeSchedule() async -> Outcome {
        await runAsAdministrator(
            shellScript: LidCloseSleep.cancelScheduleCommand,
            prompt: String(localized: "Peering will take away the daily wake it set for this Mac.")
        )
    }

    /// What is scheduled right now, as `pmset -g sched` prints it, minus the system's own alarms.
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
    ///
    /// `osascript` rather than an `AuthorizationRef` so that the password is typed into the dialog
    /// macOS owns, is never seen by this process, and is not this app's to keep.
    ///
    /// A dismissal is recognised rather than reported as a failure: `osascript` exits non-zero
    /// when the dialog is put away, and someone who has just declined is not owed an error message
    /// about having declined.
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

    /// What a finished process said.
    struct Output: Sendable {
        var status: Int32
        var out: String
        var err: String
    }

    /// Runs one process to completion and collects what it said.
    ///
    /// **Both pipes are drained before the wait.** A child that fills a pipe buffer blocks until
    /// somebody reads it, so waiting first and reading afterwards is a deadlock, and the shape it
    /// takes here is the worst one available: an authentication dialog sitting on screen while the
    /// app that asked for it waits forever for the answer.
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
        // the app that asked for it waiting forever behind it. None of the four commands this runs
        // today writes enough to fill a pipe buffer, which makes the deadlock unlikely rather than
        // impossible, and unlikely stops being true the first time one of them is replaced.
        //
        // The second read goes to another queue and is handed back through a semaphore, which is
        // what orders the two threads: the box is written before the signal and read only after the
        // wait, so the annotation below is a statement about that ordering rather than a hope.
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
    ///
    /// Everything above blocks on a child process, and one of them can block for as long as it
    /// takes a person to type a password. On the main actor that is a frozen window behind the
    /// authentication dialog, so the model calls these from the main actor and they run here.
    private static func offTheMainThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
}

/// One pipe's worth of bytes, carried across a thread boundary exactly once.
///
/// A reference type rather than a captured `var`, because a closure that mutates a local is not
/// `Sendable` and this project is in Swift 6 language mode. `@unchecked` is the honest annotation
/// for what it is: the box has no synchronisation of its own, and it does not need any because the
/// only reader waits on the semaphore the only writer signals. Anything that ever reads it from a
/// second place would make this comment false.
private final class PipeOutput: @unchecked Sendable {
    var data = Data()
}

/// The row for "keep this Mac awake": one power assertion, held for as long as the host runs.
///
/// **A row rather than a switch drawn wherever it is wanted, and it took a third copy to get
/// there.** The Settings pane had this written out by hand and the onboarding was about to make it
/// three. The two places that draw rows share this one now; the menu bar cannot, because a menu
/// item is a `Toggle` in a menu builder rather than a row in a `VStack`, and that copy is the price
/// of the menu existing at all.
///
/// The caption is doing the job ``LidCloseSleepRow`` explains at length. Of the two switches on
/// this subject this is the one that is free, silent and does not survive the lid, and a user who
/// read only the first of the two would come back from a shut lid believing they had bought that.
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
                // Named rather than pointed at. The rows between this one and the lid row are about
                // *when* this applies, so "the next row" stopped being true the moment they existed.
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
///
/// **Sits under the switch it governs, because it is not a third switch.** "Keep Mac awake" is a
/// statement about the Mac; this is a statement about *when* that statement applies, and the two
/// are only ever read together. Switched off, the rows above behave exactly as they did before this
/// existed, down to the timer not existing.
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
                    // An end before the start is a window across midnight rather than a mistake,
                    // and saying so is the difference between a setting that reads as broken and
                    // one that reads as late.
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
    ///
    /// **The second half is the part somebody has to know before they switch it on.** This can only
    /// ever let the Mac sleep, never wake it: a window that opens while the Mac is asleep does
    /// nothing at all, and the Mac comes back when something else wakes it. A row that promised to
    /// wake it at seven would be promising the one thing macOS will not do for a sleeping machine.
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
///
/// **The other half of the schedule, and the half macOS does for us.** Letting the Mac go at night
/// is only useful if something brings it back, and a Mac that is asleep cannot start its own timer.
/// `pmset` writes the wake into the machine's own schedule, which fires with nothing running and
/// nothing on the network: wake-on-LAN is a broadcast to a LAN, and a phone arriving over the relay
/// is not on one.
///
/// It is a request rather than a promise, and the caption says so. Nothing here can know whether the
/// wake will fire, so the row reports what was written rather than what will happen.
struct WakeScheduleRow: View {
    @Environment(HostModel.self) private var model

    /// Whether the "this replaces what is there" question is up.
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
        // Read when the row appears rather than at launch: both are `pmset` reads, and a setting
        // somebody changed by hand since is exactly what this is here to show.
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
///
/// **Separate from "Keep Mac awake" above it, because the two are different bargains.** That
/// switch holds a power assertion: free, silent, released when this process ends, and no promise
/// at all about a closed lid. This one changes a machine setting through an administrator rule.
/// One switch for both would take a password for something that never needed one and would hide
/// the price of the half that does.
///
/// The explanation is owed before the prompt rather than in the caption alone, because it carries
/// the two things somebody would be annoyed to find out afterwards: that the Mac does not sleep at
/// all while this is on, on battery included, and that agreeing leaves a file in `/etc/sudoers.d`.
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
            // not to claim it is, and the difference between those two is this line.
            // And not when something let it go on purpose. The schedule's window closing, and the
            // prompt on the last disconnect, both leave this switch on over a machine that is
            // sleeping normally, which is the same reading as a setting somebody removed by hand
            // and the opposite of a problem.
            if model.keepRunningWithLidClosed, !model.keepAwakeWithheld,
               model.lidCloseSystemState == .off {
                Text("Switched on, but this Mac is not doing it: pmset reports the setting as off. Switch this off and on again to put it back.")
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }

            if model.lidCloseRuleInstalled == true {
                // What the rule is, in the commands themselves rather than in a summary of them:
                // the question asked before leaving a file in /etc/sudoers.d is exactly "what does
                // this let the app run", and the answer fits on one line.
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
        // Read when the pane is opened rather than once at launch, so that a rule removed or added
        // by hand in another window is what the row is describing.
        .task { await model.checkLidCloseSleepRule() }
    }

    /// The price, before anything is asked for.
    ///
    /// Three paragraphs for three things, in the order they matter to the person reading: what
    /// macOS will not do for this app, what the rule can and cannot do, and what being on means
    /// for the machine in front of them.
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
    ///
    /// The expensive half is the administrator rule, and it is asked for once. A machine that
    /// already has it needs no second prompt, so turning this back on later is instant and silent.
    private func apply(_ wanted: Bool) {
        if wanted, model.lidCloseRuleInstalled != true {
            explaining = true
        } else {
            Task { await model.setKeepRunningWithLidClosed(wanted) }
        }
    }
}

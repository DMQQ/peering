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
            Analytics.failed(error, in: .sleepPrevention)
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
final class PipeOutput: @unchecked Sendable {
    var data = Data()
}

import Foundation
import IOKit.pwr_mgt
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

// MARK: - Sleep prevention

extension HostModel {
    static let keepRunningWithLidClosedKey = "keepRunningWithLidClosed"

    /// disablesleep outlives this process and a crash, and nothing records who set it, so this marker is how the app undoes only its own work.
    static let sleepDisabledByThisAppKey = "sleepDisabledByThisApp"

    /// A failure leaves the marker in place on purpose: the next launch is the next chance to undo it.
    func restoreSleepDisabledIfOurs() {
        guard UserDefaults.standard.bool(forKey: Self.sleepDisabledByThisAppKey) else { return }
        switch LidCloseSleepControl.restoreSleepSilently() {
        case .done:
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        case .failed(let message):
            // Straight to the unified log rather than ``record(_:level:)``: the window is closing
            // and an entry in a list nobody will read is not a diagnostic.
            hostLog.notice("could not restore lid-close sleep on quit: \(message, privacy: .public)")
        case .cancelled:
            break
        }
    }

    /// PreventSystemSleep (as caffeinate -s) is process-scoped, so it can never leave a Mac unable to sleep. It does not reliably cover a lid close; that is pmset disablesleep, the switch below.
    /// The switch records an intention and the schedule decides what is held, even with no schedule set, so a switch flipped at midnight cannot hand back assertions on a Mac with its window shut. See applyKeepAwakeSchedule().
    func setPreventLidCloseSleep(_ on: Bool) {
        Analytics.track(.lidCloseChanged)
        preventLidCloseSleep = on
        UserDefaults.standard.set(on, forKey: "preventLidCloseSleep")
        keepAwakeReleasedByHand = false
        Task { await applyKeepAwakeSchedule() }
    }

    func acquireLidSleepAssertion() {
        guard lidSleepAssertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            "PreventSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Peering lid-close sleep prevention" as CFString,
            &lidSleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire lid sleep assertion (IOReturn \(result, privacy: .public))")
            record("Could not keep the Mac awake (power assertion \(result))", level: .failure)
        } else {
            record("Keep-awake enabled; macOS does not require a permission prompt", level: .info)
        }
    }

    func releaseLidSleepAssertion() {
        guard lidSleepAssertionID != 0 else { return }
        IOPMAssertionRelease(lidSleepAssertionID)
        lidSleepAssertionID = 0
    }

    func acquirePreferenceDisplaySleepAssertion() {
        guard preferenceDisplaySleepAssertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Peering keep-awake preference" as CFString,
            &preferenceDisplaySleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire display sleep assertion (IOReturn \(result, privacy: .public))")
            record("Could not keep the display awake (power assertion \(result))", level: .failure)
        }
    }

    func releasePreferenceDisplaySleepAssertion() {
        guard preferenceDisplaySleepAssertionID != 0 else { return }
        IOPMAssertionRelease(preferenceDisplaySleepAssertionID)
        preferenceDisplaySleepAssertionID = 0
    }

    // MARK: - The schedule

    static let keepAwakeScheduleEnabledKey = "keepAwakeScheduleEnabled"
    static let keepAwakeScheduleStartHourKey = "keepAwakeScheduleStartHour"
    static let keepAwakeScheduleEndHourKey = "keepAwakeScheduleEndHour"

    static let keepAwakeDefaultStartHour = 7
    static let keepAwakeDefaultEndHour = 23

    static let keepAwakeScheduleInterval: TimeInterval = 60

    /// An end before a start crosses midnight; equal hours cover the whole day.
    func keepAwakeHoursCover(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        let start = keepAwakeStartHour
        let end = keepAwakeEndHour
        if start == end { return true }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    /// A connected client is always inside: letting go of an assertion under a live session blacks the stream (the display sleeps).
    var keepAwakeIsInForce: Bool {
        if keepAwakeReleasedByHand { return false }
        guard keepAwakeScheduleEnabled else { return true }
        if !connectedClients.isEmpty { return true }
        return keepAwakeHoursCover(Date())
    }

    /// The intention stays in preventLidCloseSleep and keepRunningWithLidClosed, so the window opening again puts everything back.
    func applyKeepAwakeSchedule() async {
        let wanted = keepAwakeIsInForce

        if wanted, preventLidCloseSleep {
            acquireLidSleepAssertion()
            acquirePreferenceDisplaySleepAssertion()
        } else {
            releaseLidSleepAssertion()
            releasePreferenceDisplaySleepAssertion()
        }

        // The machine setting only when the silent path exists: pmset needs rights, and reaching for them on a clock would raise a password dialog with nobody at the machine.
        if keepRunningWithLidClosed, lidCloseRuleInstalled == true {
            // Compared against the cached reading, not re-read: this runs on a clock and pmset -g is a subprocess. Every path that moves the setting updates the cache, and the pane re-reads on open.
            let target: LidCloseSleep.SleepDisabledState = wanted ? .on : .off
            if lidCloseSystemState != target {
                let outcome = await LidCloseSleepControl.setSleepDisabled(wanted)
                if case .failed(let message) = outcome {
                    hostLog.notice("""
                        schedule could not move lid-close sleep to \(wanted, privacy: .public): \
                        \(message, privacy: .public)
                        """)
                }
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
            }
        }

        keepAwakeWithheld = !wanted
            && (preventLidCloseSleep || keepRunningWithLidClosed)
    }

    func updateKeepAwakeScheduleWatch() {
        keepAwakeScheduleTask?.cancel()
        keepAwakeScheduleTask = nil

        guard keepAwakeScheduleEnabled else {
            // Whatever the schedule was holding goes back the moment it stops being in charge.
            Task { await applyKeepAwakeSchedule() }
            return
        }

        keepAwakeScheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.applyKeepAwakeSchedule()
                try? await Task.sleep(for: .seconds(Self.keepAwakeScheduleInterval))
            }
        }
    }

    func setKeepAwakeSchedule(enabled: Bool) {
        Analytics.track(.keepAwakeScheduleChanged)
        keepAwakeScheduleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keepAwakeScheduleEnabledKey)
        keepAwakeReleasedByHand = false
        updateKeepAwakeScheduleWatch()
    }

    func setKeepAwakeHours(start: Int, end: Int) {
        keepAwakeStartHour = start
        keepAwakeEndHour = end
        UserDefaults.standard.set(start, forKey: Self.keepAwakeScheduleStartHourKey)
        UserDefaults.standard.set(end, forKey: Self.keepAwakeScheduleEndHourKey)
        keepAwakeReleasedByHand = false
        Task { await applyKeepAwakeSchedule() }
    }

    /// Lets go of everything the keep-awake switches hold until the window opens again or a client connects; the switches stay where the user put them.
    func releaseKeepAwakeNow() async {
        asksToReleaseKeepAwake = false
        // Set before the release, so the minute clock that follows reads it and does not put it all
        // straight back. See ``keepAwakeReleasedByHand``.
        keepAwakeReleasedByHand = true
        await applyKeepAwakeSchedule()
        record("Let this Mac sleep on its own again; the switches are still set as you left them.")
    }

    /// Asked late on purpose: the last disconnect is often not somebody leaving (an app switch, a dropped connection), so asking at once was a reaction and two hours later is a reminder.
    static let keepAwakePromptGrace: Duration = .seconds(7200)

    func scheduleKeepAwakePrompt() {
        keepAwakePromptTask?.cancel()
        keepAwakePromptTask = Task { [weak self] in
            try? await Task.sleep(for: Self.keepAwakePromptGrace)
            guard !Task.isCancelled, let self else { return }
            // Everything is re-checked: in two hours somebody may have reconnected, switched off, or the schedule may have let go.
            guard self.connectedClients.isEmpty,
                  self.keepAwakeIsInForce,
                  self.preventLidCloseSleep || self.keepRunningWithLidClosed
            else { return }
            self.asksToReleaseKeepAwake = true
        }
    }

    /// The switches stay where the user put them after a release, so the pane would show Keep Mac awake on over a sleeping Mac; this sentence explains why.
    var keepAwakeWithheldExplanation: String? {
        guard keepAwakeWithheld, preventLidCloseSleep || keepRunningWithLidClosed else { return nil }
        if keepAwakeReleasedByHand {
            return String(localized: "Let go when you said so. This Mac sleeps on its own from now on, and holds again when a device connects or you touch one of these switches.")
        }
        let start = String(format: "%02d:00", keepAwakeStartHour)
        return String(localized: "Outside the hours you set, so this Mac sleeps on its own. It holds again at \(start), or as soon as a device connects.")
    }

    func rearmKeepAwake() async {
        // And the prompt goes with it: nobody is left to ask.
        keepAwakePromptTask?.cancel()
        keepAwakePromptTask = nil
        asksToReleaseKeepAwake = false
        guard keepAwakeReleasedByHand else { return }
        keepAwakeReleasedByHand = false
        await applyKeepAwakeSchedule()
    }

    // MARK: - The wake schedule

    static let wakeScheduleHourKey = "wakeScheduleHour"

    /// Both are pmset reads, done together off the main thread and again whenever the row appears, to show hand edits.
    func refreshPowerReadings() async {
        otherScheduledEvents = await LidCloseSleepControl.scheduledEvents()
        idleSleepMinutes = await LidCloseSleepControl.idleSleepMinutes()
    }

    /// nil clears it. The prompt is by design: a wake time is rarely changed, so it uses the system dialog rather than widening the standing sudoers rule to pmset repeat.
    func setWakeSchedule(hour: Int?) async {
        Analytics.track(.wakeScheduleChanged)
        guard !wakeScheduleBusy else { return }
        wakeScheduleBusy = true
        defer { wakeScheduleBusy = false }
        wakeScheduleFailure = nil

        let outcome: LidCloseSleepControl.Outcome
        if let hour {
            outcome = await LidCloseSleepControl.setWakeSchedule(hour: hour)
        } else {
            outcome = await LidCloseSleepControl.clearWakeSchedule()
        }

        switch outcome {
        case .done:
            wakeScheduleHour = hour
            // nil removes the key; the read at launch expects that, not a sentinel.
            UserDefaults.standard.set(hour, forKey: Self.wakeScheduleHourKey)
            if let hour {
                record("This Mac will wake itself at \(String(LidCloseSleep.hourString(hour).prefix(5))) every day")
            } else {
                record("The daily wake is off; this Mac sleeps until something wakes it")
            }
        case .cancelled:
            return
        case .failed(let message):
            wakeScheduleFailure = message
            record("Could not change the wake schedule: \(message)", level: .failure)
        }

        await refreshPowerReadings()
    }

    // MARK: - Lid-close sleep

    /// The only public setting that survives a closed lid is pmset -a disablesleep: administrator rights, and it persists through a crash and reboot.
    /// Applied through a scoped sudoers rule so the password is asked once (see LidCloseSleep); undone on quit (prepareForTermination()) and re-examined at launch (adoptLidCloseSleepSetting()) because a crash skips the undo.
    /// The stored intention is written only once the machine has actually changed.
    func setKeepRunningWithLidClosed(_ wanted: Bool) async {
        guard !lidCloseBusy else { return }
        keepAwakeReleasedByHand = false
        lidCloseBusy = true
        defer {
            lidCloseBusy = false
            // On every exit, not at each return point, so the watchdog always moves with the switch.
            updateBatteryWatchdog()
        }
        lidCloseFailure = nil

        // The rule first: it makes the command below silent and is the only part that costs a password.
        if wanted, !(await ensureLidCloseRule()) { return }

        switch await applySleepDisabled(wanted) {
        case .cancelled:
            return
        case .failed(let message):
            lidCloseFailure = message
            record("Could not change lid-close sleep prevention: \(message)", level: .failure)
            return
        case .alreadyThere:
            // The switch follows the intention but the marker does not: this app found the Mac like this, and a marker here would make the quit path undo someone else's setting.
            keepRunningWithLidClosed = wanted
            UserDefaults.standard.set(wanted, forKey: Self.keepRunningWithLidClosedKey)
            record(wanted
                ? "This Mac was already set to stay up with the lid closed, and not by Peering; it is being left as it was found"
                : "This Mac was already sleeping normally on a closed lid",
                level: .info)
            return
        case .applied:
            break
        }

        // Read after the change, not assumed: the switch is a request.
        lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
        keepRunningWithLidClosed = wanted
        UserDefaults.standard.set(wanted, forKey: Self.keepRunningWithLidClosedKey)
        // The marker records a change this app made; the quit and launch paths read it.
        UserDefaults.standard.set(wanted, forKey: Self.sleepDisabledByThisAppKey)
        record(wanted
            ? "Lid-close sleep prevention on; this Mac stays up with the lid shut, on battery included"
            : "Lid-close sleep prevention off; this Mac sleeps on a closed lid again")

        // Then the schedule gets its say, which outside its window hands the machine straight back.
        await applyKeepAwakeSchedule()
    }

    /// A minute against a ten per cent threshold.
    static let batteryCheckInterval: TimeInterval = 60

    /// The backstop the other paths cannot be: a Mac shut in a bag at ninety per cent has no quit, relaunch or user coming.
    func updateBatteryWatchdog() {
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        guard keepRunningWithLidClosed else { return }

        batteryWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.batteryCheckInterval))
                guard let self, !Task.isCancelled, self.keepRunningWithLidClosed else { return }

                let state = await LidCloseSleepControl.batteryState()
                guard LidCloseSleep.batteryIsLow(state) else { continue }

                // Through the ordinary path, not pmset behind the model's back, so the switch, marker and machine move together.
                await self.setKeepRunningWithLidClosed(false)
                self.record(
                    "Battery is down to \(LidCloseSleep.batteryFloor)%, so this Mac sleeps normally again. Kept awake with the lid shut it would have run the battery flat rather than sleeping through the last of it.",
                    level: .info
                )
                return
            }
        }
    }

    func enableLidCloseSleep() async {
        await setKeepRunningWithLidClosed(true)
    }

    /// Asked of sudo rather than the disk, and re-asked whenever the pane opens, to catch a hand-removed rule.
    func checkLidCloseSleepRule() async {
        guard let grants = await LidCloseSleepControl.ruleGrants() else {
            lidCloseRuleInstalled = nil
            return
        }
        lidCloseRuleInstalled = grants.coversBoth
    }

    /// One prompt undoes the setting too: both halves run as root in one script, in that order, because the rule is what lets this app turn the setting off later.
    func removeLidCloseRule() async {
        guard !lidCloseBusy else { return }
        lidCloseBusy = true
        defer { lidCloseBusy = false }
        lidCloseFailure = nil

        switch await LidCloseSleepControl.removeRule() {
        case .cancelled:
            return
        case .failed(let message):
            lidCloseFailure = message
            record("Could not remove the administrator sleep rule: \(message)", level: .failure)
        case .done:
            lidCloseRuleInstalled = false
            keepRunningWithLidClosed = false
            UserDefaults.standard.set(false, forKey: Self.keepRunningWithLidClosedKey)
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
            updateBatteryWatchdog()
            record("Administrator sleep rule removed; this Mac sleeps on a closed lid again")
        }
    }

    /// The crash path: a clean quit undoes the setting and clears the marker, a crash does neither and disablesleep survives. The answers are in LidCloseSleep/launchAction(systemState:setByThisApp:isPreferred:), unit-tested because undoing someone else's setting cannot be reproduced by crashing a process.
    func adoptLidCloseSleepSetting() async {
        let state = await LidCloseSleepControl.sleepDisabledState()
        // Kept so the row can say when the machine disagrees with the switch.
        lidCloseSystemState = state

        // Drop a claim about a setting that is gone: a stale marker plus another tool later setting disablesleep reads as on and ours, and quit would turn that tool's setting off. Not on .unknown, or a failed reading would orphan a Mac unable to sleep.
        if LidCloseSleep.shouldForgetOwnership(systemState: state) {
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        }

        // Also at launch because the menu bar draws the same switch; sudo -n -l cannot raise a dialog and costs milliseconds.
        await checkLidCloseSleepRule()

        let setByThisApp = UserDefaults.standard.bool(forKey: Self.sleepDisabledByThisAppKey)
        switch LidCloseSleep.launchAction(
            systemState: state,
            setByThisApp: setByThisApp,
            isPreferred: keepRunningWithLidClosed
        ) {
        case .keep:
            record("This Mac is still set to stay up with the lid closed")
        case .restore:
            switch LidCloseSleepControl.restoreSleepSilently() {
            case .done:
                UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
                // Re-read after the change: the earlier reading predates it, and assuming would show a restored Mac as still disabled.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Sleep was still disabled by Peering from a previous run; this Mac sleeps on a closed lid again")
            case .failed(let message):
                lidCloseFailure = message
                // Two sentences: the command's own words have no full stop.
                record("This Mac still will not sleep with the lid closed. Switching the row off and on again in Settings is the repair. The command said: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .reapply:
            switch await LidCloseSleepControl.setSleepDisabled(true) {
            case .done:
                UserDefaults.standard.set(true, forKey: Self.sleepDisabledByThisAppKey)
                // Without this the cached reading stays at the .off that made the re-apply necessary.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Lid-close sleep prevention re-applied; it had been cleared on this Mac since the last run")
            case .failed(let message):
                lidCloseFailure = message
                record("Lid-close sleep prevention is switched on but not in force: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .leaveAlone:
            // Not ours to undo, and saying so is the point: nothing else explains why a Mac stopped sleeping on its lid.
            record("This Mac has sleep disabled and Peering did not do it, so it is being left alone")
        case .none:
            break
        }

        // After every path above: a setting that survived a crash means a Mac up with its lid shut since before this process, when a battery check matters most.
        updateBatteryWatchdog()

        // A second schedule pass now the rule has been read: the first runs from init while lidCloseRuleInstalled is nil and will not touch the machine setting. It also restores assertions, which do not survive the process.
        await applyKeepAwakeSchedule()
    }

    /// Checked after installing and assumed false when sudo will not say: the file is written by another process as root, so only sudo knows.
    func ensureLidCloseRule() async -> Bool {
        // The cache is re-checked: the file may have been removed since the pane opened, and trusting it would skip the install prompt and then fail the command with a raw sudo refusal.
        if lidCloseRuleInstalled == true {
            await checkLidCloseSleepRule()
            if lidCloseRuleInstalled == true { return true }
        }

        switch await LidCloseSleepControl.installRule(user: LidCloseSleepControl.invokingUserName) {
        case .cancelled:
            return false
        case .failed(let message):
            lidCloseFailure = message
            record("Could not install the administrator sleep rule: \(message)", level: .failure)
            return false
        case .done:
            await checkLidCloseSleepRule()
            guard lidCloseRuleInstalled == true else {
                lidCloseFailure = String(localized: "The rule was written, but sudo does not report it. This Mac has not been changed.")
                record("The administrator sleep rule was installed but does not take effect", level: .failure)
                return false
            }
            record("Administrator sleep rule installed, granting two pmset commands and nothing else")
            return true
        }
    }

    /// Four outcomes, one more than LidCloseSleepControl.Outcome: alreadyThere means the Mac is where it was asked and this app did not put it there, so no marker may be written or quit would stop it sleeping.
    enum SleepApplication {
        case applied
        case alreadyThere
        case cancelled
        case failed(String)
    }

    /// A password is asked only if the silent route has nothing to offer, which matters when turning the switch off with the rule gone: a Mac with sleep disabled cannot otherwise be put back.
    /// alreadyThere is read before the prompt and is never a success: the setting is from somewhere else.
    func applySleepDisabled(_ wanted: Bool) async -> SleepApplication {
        let target: LidCloseSleep.SleepDisabledState = wanted ? .on : .off

        // Read before writing: sudo -n pmset -a disablesleep 1 exits 0 whether it flipped the setting or found it flipped, and claiming another tool's setting would make quit turn it off.
        if await LidCloseSleepControl.sleepDisabledState() == target { return .alreadyThere }

        let outcome = await LidCloseSleepControl.setSleepDisabled(wanted)
        if case .cancelled = outcome { return .cancelled }

        if case .failed(let message) = outcome {
            // Re-read, not believed: this is where the rule was just deleted by hand and turning the switch off is the only way to undo a Mac that stopped sleeping.
            await checkLidCloseSleepRule()
            guard lidCloseRuleInstalled != true else { return .failed(message) }
            return Self.application(of: await LidCloseSleepControl.setSleepDisabledAskingForAdmin(
                wanted,
                prompt: wanted
                    ? String(localized: "Peering will stop this Mac sleeping with the lid closed.")
                    : String(localized: "Peering will let this Mac sleep normally again.")
            ))
        }

        return .applied
    }

    static func application(of outcome: LidCloseSleepControl.Outcome) -> SleepApplication {
        switch outcome {
        case .done: return .applied
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }
}

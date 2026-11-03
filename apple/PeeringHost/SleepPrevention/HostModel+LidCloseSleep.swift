import Foundation
import RemoteCore

extension HostModel {
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

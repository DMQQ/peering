import Foundation
import IOKit.pwr_mgt
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

// MARK: - Sleep prevention

extension HostModel {
    static let keepRunningWithLidClosedKey = "keepRunningWithLidClosed"

    /// The key that records that it was *this app* that ran `pmset -a disablesleep 1`.
    ///
    /// `disablesleep` is a machine setting, not an assertion: it outlives this process and a crash,
    /// so a host that dies with the switch on leaves a laptop that will not sleep in a bag. Nothing
    /// on the machine records who set it, so undoing this app's own work without undoing somebody
    /// else's means having written that fact down first.
    static let sleepDisabledByThisAppKey = "sleepDisabledByThisApp"

    /// Puts the machine back to sleeping normally, if it was this app that stopped it.
    ///
    /// A failure here leaves the marker in place on purpose: the setting is still on, and the next
    /// launch is the next chance to undo it.
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

    /// Toggles what the settings screen calls "Keep Mac awake": the free half of sleep prevention.
    ///
    /// The type is `PreventSystemSleep`, the one `caffeinate -s` acquires, and it stops the Mac
    /// sleeping on its own: idle timers, a stalled download, nothing to do. Closing the lid is a
    /// different path in macOS, and whether the assertion covers it depends on the machine. What
    /// survives a lid close on every Mac is `pmset -a disablesleep 1`, which needs administrator
    /// rights and is the switch below rather than this one.
    ///
    /// Being process-scoped is the property worth having here: the OS releases the assertion when
    /// this process exits, so this switch can never leave a Mac unable to sleep.
    func setPreventLidCloseSleep(_ on: Bool) {
        preventLidCloseSleep = on
        UserDefaults.standard.set(on, forKey: "preventLidCloseSleep")
        if on {
            acquireLidSleepAssertion()
            acquirePreferenceDisplaySleepAssertion()
        } else {
            releaseLidSleepAssertion()
            releasePreferenceDisplaySleepAssertion()
        }
    }

    func acquireLidSleepAssertion() {
        guard lidSleepAssertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            "PreventSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacCast lid-close sleep prevention" as CFString,
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

    // MARK: - Lid-close sleep

    /// Turns "keep running with the lid closed" on or off.
    ///
    /// The switch the assertion above cannot be: the only public setting that survives a closed lid
    /// is `pmset -a disablesleep`, which needs administrator rights and, once set, stays set through
    /// this process, a crash and a reboot. Three things follow from that:
    ///
    /// It is applied through a scoped sudoers rule rather than by prompting every time, so the
    /// password is asked for once. ``LidCloseSleep`` holds the text of that rule and what keeps it
    /// from granting more than the window promises.
    ///
    /// It is undone on the way out (``HostModel/prepareForTermination()``), because a Mac left
    /// unable to sleep with nothing on screen to explain it is worse than the feature is good.
    ///
    /// And it is re-examined on the way in (``adoptLidCloseSleepSetting()``), because a crash skips
    /// the first of those and the setting survives the crash.
    ///
    /// The stored intention is written only once the machine has actually been changed, so the
    /// switch being on is a statement about the Mac rather than about the last click.
    func setKeepRunningWithLidClosed(_ wanted: Bool) async {
        guard !lidCloseBusy else { return }
        lidCloseBusy = true
        defer {
            lidCloseBusy = false
            // On every exit rather than at each of the six return points, because a switch that
            // moves without its watchdog moving with it either stops being watched or keeps a task
            // alive for nothing.
            updateBatteryWatchdog()
        }
        lidCloseFailure = nil

        // The rule comes first when it is wanted: it is what makes the command below silent, and
        // the only part of this that costs a password.
        if wanted, !(await ensureLidCloseRule()) { return }

        switch await applySleepDisabled(wanted) {
        case .cancelled:
            return
        case .failed(let message):
            lidCloseFailure = message
            record("Could not change lid-close sleep prevention: \(message)", level: .failure)
            return
        case .alreadyThere:
            // The switch follows the intention and the marker does not follow the setting: this app
            // found the Mac like this, so undoing it is not its business, and a marker written here
            // would make the quit path do exactly that.
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

        // Read after the change rather than assumed from it: the switch is a request and this is
        // what the machine did with it.
        lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
        keepRunningWithLidClosed = wanted
        UserDefaults.standard.set(wanted, forKey: Self.keepRunningWithLidClosedKey)
        // The marker records a change this app made to the machine, which is what the quit and
        // launch paths read to know whether undoing it is this app's business.
        UserDefaults.standard.set(wanted, forKey: Self.sleepDisabledByThisAppKey)
        record(wanted
            ? "Lid-close sleep prevention on; this Mac stays up with the lid shut, on battery included"
            : "Lid-close sleep prevention off; this Mac sleeps on a closed lid again")
    }

    /// How often the charge is read while the Mac is being kept up.
    ///
    /// A minute against a threshold of ten per cent: finer than it needs to be, and the cost of a
    /// too-fine margin is one small process a minute in the one state where the battery is at risk.
    static let batteryCheckInterval: TimeInterval = 60

    /// Starts or stops the battery check, to match the switch.
    ///
    /// The rail the other three do not replace: restoring on quit needs the app to be quit, the
    /// launch repair needs it to be launched again, and the switch needs somebody to remember it.
    /// A Mac shut in a bag at ninety per cent has none of those coming.
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

                // Turned off through the ordinary path rather than by running `pmset` behind the
                // model's back, so the switch, the marker and the machine all move together and the
                // pane does not go on reading "on" over a Mac allowed to sleep.
                await self.setKeepRunningWithLidClosed(false)
                self.record(
                    "Battery is down to \(LidCloseSleep.batteryFloor)%, so this Mac sleeps normally again. Kept awake with the lid shut it would have run the battery flat rather than sleeping through the last of it.",
                    level: .info
                )
                return
            }
        }
    }

    /// The same thing, under the name the confirmation dialog calls it by.
    func enableLidCloseSleep() async {
        await setKeepRunningWithLidClosed(true)
    }

    /// Reads whether the administrator rule is doing its job.
    ///
    /// Asked of `sudo` rather than of the disk, and re-asked every time the settings pane opens, so
    /// a rule someone removed by hand is what the row ends up describing.
    func checkLidCloseSleepRule() async {
        guard let grants = await LidCloseSleepControl.ruleGrants() else {
            lidCloseRuleInstalled = nil
            return
        }
        lidCloseRuleInstalled = grants.coversBoth
    }

    /// Takes the administrator rule away again, for someone who wants it gone.
    ///
    /// One prompt, and the same prompt undoes the setting: both halves run as root in one shell
    /// script in that order, because the rule is what lets this app turn the setting off later.
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

    /// Puts the machine and the switch back into agreement, once, at launch.
    ///
    /// The crash path: a clean quit turns the setting back off and clears the marker, a crash does
    /// neither, and `disablesleep` survives a crash and a reboot, so what this finds is a Mac left
    /// unable to sleep some time ago. The three answers it can reach are in
    /// ``LidCloseSleep/launchAction(systemState:setByThisApp:isPreferred:)``, which is a value with
    /// tests because the mistake worth preventing, undoing a setting somebody else made, cannot be
    /// reproduced on demand by crashing a process.
    func adoptLidCloseSleepSetting() async {
        let state = await LidCloseSleepControl.sleepDisabledState()
        // What the machine is doing, kept so the row can say when it disagrees with the switch: the
        // switch is the intention and this is the reading, and a crash, a force quit or a hand edit
        // puts the two out of step.
        lidCloseSystemState = state

        // Where a claim about a setting that is gone gets dropped. The marker says this app turned
        // the setting on; a reading of `off` says it is not on, whoever did it, so keeping the claim
        // can only do harm: a stale marker plus some other tool later setting `disablesleep` reads
        // as "on, and ours" at the next launch, and the quit path then turns that tool's setting
        // off. Not done on `.unknown`, because forgetting ownership on a failed reading is how a Mac
        // ends up unable to sleep with nothing left claiming it.
        if LidCloseSleep.shouldForgetOwnership(systemState: state) {
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        }

        // Asked at launch as well as when the Settings pane opens, because the menu bar draws the
        // same switch and is where it is usually flipped from; without it the menu has to guess
        // between a switch that silently fails and a door to a window nobody wanted to open.
        // `sudo -n -l` cannot raise a dialog, so it costs milliseconds and nothing else.
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
                // Re-read after the change, the way ``setKeepRunningWithLidClosed(_:)`` does: the
                // reading above was taken before this ran and it is the reading the menu draws.
                // Assumed instead of read, a Mac this function has just restored reports itself as
                // still disabled for the rest of the session.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Sleep was still disabled by Peering from a previous run; this Mac sleeps on a closed lid again")
            case .failed(let message):
                lidCloseFailure = message
                // Two sentences rather than one with a description spliced in: the command's own
                // words have no full stop to end them.
                record("This Mac still will not sleep with the lid closed. Switching the row off and on again in Settings is the repair. The command said: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .reapply:
            switch await LidCloseSleepControl.setSleepDisabled(true) {
            case .done:
                UserDefaults.standard.set(true, forKey: Self.sleepDisabledByThisAppKey)
                // Without this, every launch that re-applies the setting leaves the cached reading
                // at the `.off` that made the re-apply necessary, and the menu says "not in force"
                // over a Mac that is.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Lid-close sleep prevention re-applied; it had been cleared on this Mac since the last run")
            case .failed(let message):
                lidCloseFailure = message
                record("Lid-close sleep prevention is switched on but not in force: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .leaveAlone:
            // Not ours to undo, and saying so is the point: nothing else in this app can explain why
            // a Mac has stopped sleeping on its lid.
            record("This Mac has sleep disabled and Peering did not do it, so it is being left alone")
        case .none:
            break
        }

        // Reachable after every path above, including the ones that changed nothing: a switch that
        // survived a crash is a Mac that has been up with its lid shut since before this process
        // started, which is when a battery check is most worth having.
        updateBatteryWatchdog()
    }

    /// Puts the rule in place if it is not there, and answers whether it ended up there.
    ///
    /// Checked after installing rather than assumed, and assumed false when `sudo` will not say: the
    /// file is written by another process as root, and the only trustworthy answer about what `sudo`
    /// will do next is `sudo`'s own.
    func ensureLidCloseRule() async -> Bool {
        // The cache is re-checked before it is trusted. It is filled when the Settings pane opens
        // and the file can be gone since, deleted by hand, removed by the button, or never installed
        // for this account. Trusting it means skipping the install prompt and then failing the very
        // command it was there to make silent, leaving the switch on with nothing behind it and the
        // raw refusal from `sudo` on screen.
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
                lidCloseFailure = "The rule was written, but sudo does not report it. This Mac has not been changed."
                record("The administrator sleep rule was installed but does not take effect", level: .failure)
                return false
            }
            record("Administrator sleep rule installed, granting two pmset commands and nothing else")
            return true
        }
    }

    /// How an attempt to change the machine setting ended, in the four ways it can.
    ///
    /// Four rather than the three ``LidCloseSleepControl/Outcome`` has, because ``alreadyThere``
    /// means the Mac is where it was asked to be and this app did not put it there. That has to be
    /// told apart from a change this app made: the marker that lets it undo its own work on quit
    /// must not be written for somebody else's setting, or the Mac stops sleeping the first time
    /// Peering quits.
    enum SleepApplication {
        /// This app ran the command and the machine changed.
        case applied
        /// The machine was already in the wanted state, and not because of this app.
        case alreadyThere
        case cancelled
        case failed(String)
    }

    /// Applies the setting, asking for a password only if the silent route has nothing to offer.
    ///
    /// The rule is normally what makes this silent, and it can be gone, deleted by hand or by the
    /// button in Settings. The case that matters then is turning the switch *off*: a Mac whose sleep
    /// is disabled and whose rule has been taken away cannot be put back any other way, and a switch
    /// that will not turn off is worse than one password prompt. The prompt is skipped when the
    /// machine is already where it was asked to be.
    ///
    /// The already-there answer is read before the prompt is considered and never as a success: a
    /// Mac already in the wanted state when the silent command fails has its setting from somewhere
    /// else, and there is nothing for this app to do or to claim.
    func applySleepDisabled(_ wanted: Bool) async -> SleepApplication {
        let target: LidCloseSleep.SleepDisabledState = wanted ? .on : .off

        // Read before writing, because an exit status cannot tell a change from an agreement:
        // `sudo -n pmset -a disablesleep 1` exits 0 whether it flipped the setting or found it
        // already flipped, and the difference is who owns it. Claiming a setting another tool
        // disabled would make the quit path turn that tool's setting off.
        if await LidCloseSleepControl.sleepDisabledState() == target { return .alreadyThere }

        let outcome = await LidCloseSleepControl.setSleepDisabled(wanted)
        if case .cancelled = outcome { return .cancelled }

        if case .failed(let message) = outcome {
            // The cache is re-read rather than believed here, which is the branch that most needs
            // it: this is where somebody arrives having just deleted the rule by hand, and where
            // turning the switch off is the only thing that can undo a Mac that has stopped
            // sleeping. Believing a stale "the rule is installed" withholds the one password prompt
            // that can still put it back.
            await checkLidCloseSleepRule()
            guard lidCloseRuleInstalled != true else { return .failed(message) }
            return Self.application(of: await LidCloseSleepControl.setSleepDisabledAskingForAdmin(
                wanted,
                prompt: wanted
                    ? "Peering will stop this Mac sleeping with the lid closed."
                    : "Peering will let this Mac sleep normally again."
            ))
        }

        return .applied
    }

    /// The privileged outcome, in the four-way spelling the caller above works in.
    static func application(of outcome: LidCloseSleepControl.Outcome) -> SleepApplication {
        switch outcome {
        case .done: return .applied
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }
}

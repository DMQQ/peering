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
    ///
    /// The switch records an intention and the schedule decides what is held.
    ///
    /// Even with no schedule set, which reads as a detour for the sake of it: going through one
    /// place is what keeps a Mac whose window is shut from being handed its assertions back by a
    /// switch somebody flipped at midnight. See ``applyKeepAwakeSchedule()``.
    func setPreventLidCloseSleep(_ on: Bool) {
        preventLidCloseSleep = on
        UserDefaults.standard.set(on, forKey: "preventLidCloseSleep")
        // Flipping the switch is the user asking for it again, whatever they answered when the
        // prompt offered to let the Mac go.
        keepAwakeReleasedByHand = false
        Task { await applyKeepAwakeSchedule() }
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

    // MARK: - The schedule

    static let keepAwakeScheduleEnabledKey = "keepAwakeScheduleEnabled"
    static let keepAwakeScheduleStartHourKey = "keepAwakeScheduleStartHour"
    static let keepAwakeScheduleEndHourKey = "keepAwakeScheduleEndHour"

    /// Seven in the morning to eleven at night: a guess at somebody's working day, and a guess is
    /// why the row lets them move it.
    static let keepAwakeDefaultStartHour = 7
    static let keepAwakeDefaultEndHour = 23

    /// How often the clock is consulted. A minute, against a window that is measured in hours.
    static let keepAwakeScheduleInterval: TimeInterval = 60

    /// Whether the hour `date` falls in is inside the window.
    ///
    /// An end before a start crosses midnight, which is the shape somebody actually wants when they
    /// want the Mac up in the evening and down in the morning. Equal hours cover the whole day,
    /// because a zero-width window is not a thing anybody means to ask for.
    func keepAwakeHoursCover(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        let start = keepAwakeStartHour
        let end = keepAwakeEndHour
        if start == end { return true }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    /// Whether a keep-awake the user asked for should be in force right now.
    ///
    /// **A connected client is always inside.** The point of this is to stop the Mac being up when
    /// nobody is using it, and letting go of an assertion under a session that has already started
    /// is the one thing it must not do: the display sleeps, and ScreenCaptureKit turns a healthy
    /// stream into black frames.
    var keepAwakeIsInForce: Bool {
        if keepAwakeReleasedByHand { return false }
        guard keepAwakeScheduleEnabled else { return true }
        if !connectedClients.isEmpty { return true }
        return keepAwakeHoursCover(Date())
    }

    /// Puts what is being *held* where ``keepAwakeIsInForce`` says it belongs, without touching
    /// what the user asked for.
    ///
    /// The intention stays in `preventLidCloseSleep` and `keepRunningWithLidClosed`, and that is
    /// what makes this reversible: the window opens again and the same switches put everything back
    /// with nobody having to remember which of them were on.
    func applyKeepAwakeSchedule() async {
        let wanted = keepAwakeIsInForce

        if wanted, preventLidCloseSleep {
            acquireLidSleepAssertion()
            acquirePreferenceDisplaySleepAssertion()
        } else {
            releaseLidSleepAssertion()
            releasePreferenceDisplaySleepAssertion()
        }

        // **The machine setting, and only when the silent path is there.** `pmset` needs rights,
        // and a schedule that reached for them on a clock would raise a password dialog with nobody
        // at the machine and then leave the Mac exactly as it was. The rule is what makes this path
        // silent; without it the row says so rather than the schedule guessing.
        if keepRunningWithLidClosed, lidCloseRuleInstalled == true {
            // **Compared against the cached reading rather than read again.** This runs on a clock,
            // and `pmset -g` is a subprocess: a Mac inside its window all day would spawn one a
            // minute to be told nothing had changed. Every path that moves the setting updates the
            // reading, and the pane re-reads it when it opens, which is where a setting somebody
            // moved by hand is noticed.
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

    /// Starts or stops the clock that opens and closes the window, and re-applies either way.
    ///
    /// No timer at all when the schedule is off, so a Mac that is not using this pays nothing for
    /// it: the two switches then behave exactly as they did before it existed.
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

    /// Lets go of everything the keep-awake switches are holding, now, until the window opens again
    /// or a client connects.
    ///
    /// Called from the prompt on the last disconnect, and it is the same act the window's close
    /// performs: the switches are left where the user put them, so nothing has to be remembered to
    /// undo this.
    func releaseKeepAwakeNow() async {
        asksToReleaseKeepAwake = false
        // Set before the release, so the minute clock that follows reads it and does not put it all
        // straight back. See ``keepAwakeReleasedByHand``.
        keepAwakeReleasedByHand = true
        await applyKeepAwakeSchedule()
        record(String(localized: "Let this Mac sleep on its own again; the switches are still set as you left them."))
    }

    /// How long the Mac is left alone before it asks whether it should still be awake.
    ///
    /// **Asked late, and the delay is the whole of why it is bearable.** The trigger is the last
    /// client disconnecting, and that happens for reasons that are not somebody leaving: a phone
    /// that switched apps, a connection that dropped and is about to come back, a deliberate look at
    /// the picker, an evening spent away from the desk without ending the session first. Asked on
    /// the instant, the question was a reaction to a disconnect; asked two hours later, it is a
    /// reminder about a Mac that really has been sitting there awake for nobody.
    static let keepAwakePromptGrace: Duration = .seconds(7200)

    /// Arms that question, replacing any already armed.
    func scheduleKeepAwakePrompt() {
        keepAwakePromptTask?.cancel()
        keepAwakePromptTask = Task { [weak self] in
            try? await Task.sleep(for: Self.keepAwakePromptGrace)
            guard !Task.isCancelled, let self else { return }
            // Everything is re-checked, because two minutes is long enough for the situation to
            // have gone: somebody reconnected, or turned a switch off, or the schedule's window
            // shut and the Mac let go of its own accord.
            guard self.connectedClients.isEmpty,
                  self.keepAwakeIsInForce,
                  self.preventLidCloseSleep || self.keepRunningWithLidClosed
            else { return }
            self.asksToReleaseKeepAwake = true
        }
    }

    /// Why nothing is being held, in a sentence, or `nil` when the switches are doing what they say.
    ///
    /// **The switch cannot answer this on its own, which is the whole reason this exists.** After
    /// "Let it sleep", and outside the schedule's hours, the switches are still where the user put
    /// them by design, because that is what makes the release reversible without anybody having to
    /// remember anything. The cost of that design is a pane with "Keep Mac awake" switched on over a
    /// Mac that is asleep, and a user who has to guess. This is the sentence that stops the guessing.
    var keepAwakeWithheldExplanation: String? {
        guard keepAwakeWithheld, preventLidCloseSleep || keepRunningWithLidClosed else { return nil }
        if keepAwakeReleasedByHand {
            return String(localized: "Let go when you said so. This Mac sleeps on its own from now on, and holds again when a device connects or you touch one of these switches.")
        }
        let start = String(format: "%02d:00", keepAwakeStartHour)
        return String(localized: "Outside the hours you set, so this Mac sleeps on its own. It holds again at \(start), or as soon as a device connects.")
    }

    /// Takes back a release the user asked for, when something says the situation has changed.
    func rearmKeepAwake() async {
        // And the question goes with it: somebody is using this Mac, so there is nothing left to
        // ask about, and a prompt that outlived the reason for it is one that gets dismissed by
        // reflex.
        keepAwakePromptTask?.cancel()
        keepAwakePromptTask = nil
        asksToReleaseKeepAwake = false
        guard keepAwakeReleasedByHand else { return }
        keepAwakeReleasedByHand = false
        await applyKeepAwakeSchedule()
    }

    // MARK: - The wake schedule

    static let wakeScheduleHourKey = "wakeScheduleHour"

    /// Reads the two things about this Mac's own power settings that the wake row draws.
    ///
    /// Both are `pmset` reads, so both happen together and off the main thread, and both are asked
    /// again whenever the row appears: a setting somebody changed by hand is exactly what this is
    /// here to show.
    func refreshPowerReadings() async {
        otherScheduledEvents = await LidCloseSleepControl.scheduledEvents()
        idleSleepMinutes = await LidCloseSleepControl.idleSleepMinutes()
    }

    /// Sets or clears the daily wake, through the system's own password dialog.
    ///
    /// `nil` clears it. The prompt is expected and is the design rather than a shortcoming: a wake
    /// time is set once and changed rarely, so it goes through the dialog the system owns instead of
    /// widening the standing sudoers rule to cover `pmset repeat` for every hour of the day.
    func setWakeSchedule(hour: Int?) async {
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
            // `nil` removes the key rather than writing a sentinel, which is what the read at launch
            // expects to find.
            UserDefaults.standard.set(hour, forKey: Self.wakeScheduleHourKey)
            if let hour {
                // `record` takes a plain string, so this is interpolation rather than an os_log
                // one: `privacy:` belongs to the logger and not here.
                record(String(localized: "This Mac will wake itself at \(LidCloseSleep.hourString(hour).prefix(5)) every day"))
            } else {
                record(String(localized: "The daily wake is off; this Mac sleeps until something wakes it"))
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
        // As with the switch above: asking for it is what takes back a release given to the prompt.
        keepAwakeReleasedByHand = false
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

        // And then the schedule gets its say, which outside its window is to hand the machine
        // straight back. The switch stays where the user put it either way, so the window opening
        // again is the whole of what puts this back.
        await applyKeepAwakeSchedule()
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

        // **And the schedule gets a second pass, now that the rule has been read.** The first one
        // runs from `init` before this function has finished, when ``lidCloseRuleInstalled`` is
        // still nil, so it will not touch the machine setting. Without this, a Mac launched outside
        // its own window at login would hold `disablesleep` until somebody opened the pane.
        //
        // It also puts back what the switches say should be held: the assertions are the one part of
        // this that does not survive the process, so a "Keep Mac awake" left on across a relaunch
        // was a switch reading on over a Mac that had already forgotten it.
        await applyKeepAwakeSchedule()
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

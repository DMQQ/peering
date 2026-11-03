import Foundation
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

extension HostModel {
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
}

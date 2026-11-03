import AppKit
import Foundation
import os
import PeeringKit
import RemoteCore

/// Keeps the routines, fires each one when it is due, and follows its run to the end.
///
/// Every mutable property is touched only on ``queue``.
final class AgentRoutineScheduler: @unchecked Sendable {
    /// A wall-clock tick, so time asleep counts; waking also ticks at once.
    private static let tick: DispatchTimeInterval = .seconds(30)
    static let routinesPerClient = 30

    let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.routines", qos: .utility)
    let sessions: AgentSessionManager
    let store: AgentRoutineStore
    var entries: [AgentRoutineEntry] = []
    /// False when the file could not be read: nothing is saved over it.
    var storeReadable = true
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    init(sessions: AgentSessionManager, store: AgentRoutineStore = .standard()) {
        self.sessions = sessions
        self.store = store
    }

    /// Safe to call again when the server restarts: only the first call starts the clock.
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            do {
                entries = try store.load()
            } catch {
                storeReadable = false
                agentLog.error("routines could not be read · \(String(describing: error), privacy: .public)")
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(wallDeadline: .now() + Self.tick, repeating: Self.tick, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.check(now: Date()) }
            timer.resume()
            self.timer = timer
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in self?.check(now: Date()) }
            }
        }
    }

    /// Called on ``queue``.
    func check(now: Date) {
        var changed = false
        for index in entries.indices {
            changed = follow(at: index, now: now) || changed
        }
        for index in entries.indices where isDue(entries[index], now: now) {
            fire(at: index, now: now)
            changed = true
        }
        if changed { save() }
    }

    private func isDue(_ entry: AgentRoutineEntry, now: Date) -> Bool {
        entry.routine.isEnabled
            && entry.routine.lastRun?.outcome != .running
            && AgentRoutinePlan.isDue(entry.routine.schedule, since: entry.scheduledFrom, now: now)
    }

    /// Records how a running run has got on. True when the record changed.
    private func follow(at index: Int, now: Date) -> Bool {
        guard let run = entries[index].routine.lastRun, run.outcome == .running, let id = run.sessionID else { return false }
        let status = sessions.routineChatStatus(id)
        let limit = entries[index].routine.stopAfterMinutes
        switch AgentRoutineProgress.of(state: status.state, finishedOK: status.finishedOK, startedAt: run.startedAt, now: now, stopAfterMinutes: limit) {
        case .running:
            return false
        case .overTime:
            sessions.interruptRoutineChat(id)
            let spent = Measurement(value: Double(limit ?? 0), unit: UnitDuration.minutes).formatted(.measurement(width: .wide))
            record(.stopped, detail: String(localized: "Stopped at its limit of \(spent)."), at: index)
        case .ended(let outcome):
            record(outcome, detail: Self.detail(for: outcome), at: index)
        }
        return true
    }

    private static func detail(for outcome: AgentRoutineRun.Outcome) -> String? {
        switch outcome {
        case .failed: String(localized: "The agent did not finish the run.")
        case .stopped: String(localized: "The chat was closed before the run finished.")
        case .running, .succeeded, .skipped: nil
        }
    }

    private func record(_ outcome: AgentRoutineRun.Outcome, detail: String?, at index: Int) {
        entries[index].routine.lastRun?.outcome = outcome
        entries[index].routine.lastRun?.detail = detail
        agentLog.notice("routine run ended · \(outcome.rawValue, privacy: .public)")
    }

    /// Starts a run, or records why it could not. Either way the next time is counted from now, so a missed stretch is one run.
    func fire(at index: Int, now: Date) {
        let entry = entries[index]
        entries[index].scheduledFrom = now
        if let reason = Self.reasonToSkip(entry.routine) {
            entries[index].routine.lastRun = AgentRoutineRun(startedAt: now, outcome: .skipped, detail: reason)
            agentLog.notice("routine skipped · \(entry.routine.agentID, privacy: .public)")
            return
        }
        switch sessions.startRoutineChat(entry.routine, ownerClientID: entry.ownerClientID) {
        case .started(let id):
            entries[index].routine.lastRun = AgentRoutineRun(startedAt: now, outcome: .running, sessionID: id)
        case .refused(let reason):
            entries[index].routine.lastRun = AgentRoutineRun(startedAt: now, outcome: .skipped, detail: reason)
        }
    }

    /// Looked at on this queue: finding the binary can run a login shell, and a folder check can wait on a permission dialog.
    private static func reasonToSkip(_ routine: AgentRoutine) -> String? {
        let name = AgentCatalogue.entry(for: routine.agentID)?.name ?? routine.agentID
        guard AgentEnvironment.shared.binary(named: routine.agentID) != nil else {
            return String(localized: "\(name) is not installed on this Mac.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: routine.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return String(localized: "There is no folder at \(routine.directory) on this Mac.")
        }
        return nil
    }

    func save() {
        guard storeReadable else { return }
        do { try store.save(entries) } catch {
            agentLog.error("routines could not be saved · \(String(describing: error), privacy: .public)")
        }
    }
}

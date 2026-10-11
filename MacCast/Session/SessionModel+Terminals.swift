import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    static let terminalHistoryLimit = 25

    /// De-duplicated so a repeated command moves to the top, and capped: this is a convenience, the Mac's own shell keeps the history.
    func rememberTerminalCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = terminalHistory
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > Self.terminalHistoryLimit {
            history.removeLast(history.count - Self.terminalHistoryLimit)
        }
        terminalHistory = history
        forgetTerminalHistoryIfStored(history)
    }

    func removeFromTerminalHistory(_ command: String) {
        var history = terminalHistory
        history.removeAll { $0 == command }
        terminalHistory = history
        forgetTerminalHistoryIfStored(history)
    }

    private func forgetTerminalHistoryIfStored(_ history: [String]) {
        UserDefaults.standard.set(history, forKey: PreferenceKeys.terminalHistory)
    }

    /// With no session up a note has nowhere to go, which is right: no Mac did anything.
    func append(note: String) { activeSession?.append(note: note) }

    func refreshTerminals() { activeSession?.refreshTerminals() }

    func refreshAgents() { activeSession?.refreshAgents() }

    /// Before the Mac has said, what it said last time, else nothing for a Mac that will answer: a list of all that then shrank was a blink. A Mac that cannot say gets every agent.
    var availableAgents: [TerminalAgent] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "Peering.showAllAgents") { return TerminalAgent.all }
        #endif
        guard let session = activeSession else { return TerminalAgent.all }
        guard let installed = session.knownInstalledAgents else {
            return session.hostSupportsAgentList ? [] : TerminalAgent.all
        }
        return TerminalAgent.all.filter { installed.contains($0.command) }
    }

    var isAwaitingAgentList: Bool {
        guard let session = activeSession else { return false }
        return session.hostSupportsAgentList && session.knownInstalledAgents == nil
    }

    var canOpenAnotherShell: Bool { activeSession?.canOpenAnotherShell ?? true }

    var runningShellTargetID: UUID? { activeSession?.runningShellTargetID }

    /// Written back to nil when taken, so the same arrival is not opened twice.
    var newTerminalID: UUID? {
        get { activeSession?.newTerminalID }
        set { activeSession?.newTerminalID = newValue }
    }

    func createTerminal() { Analytics.featureUsed(.terminalCreated); activeSession?.createTerminal() }

    func createTerminal(inDirectory path: String?) { Analytics.featureUsed(.terminalCreated); activeSession?.createTerminal(inDirectory: path) }

    func runInNewTerminal(_ command: String) { Analytics.featureUsed(.terminalRunCommand); activeSession?.runInNewTerminal(command) }

    func renameTerminal(_ id: UUID, to name: String) { Analytics.featureUsed(.terminalRenamed); activeSession?.renameTerminal(id, to: name) }

    func selectTerminal(_ id: UUID) { activeSession?.selectTerminal(id) }

    func sendTerminalInput(_ text: String, to id: UUID, appendReturn: Bool = true) {
        activeSession?.sendTerminalInput(text, to: id, appendReturn: appendReturn)
    }

    func sendTerminalBytes(_ bytes: [UInt8], to id: UUID) {
        activeSession?.sendTerminalBytes(bytes, to: id)
    }

    func resizeTerminal(_ id: UUID, columns: Int, rows: Int) {
        activeSession?.resizeTerminal(id, columns: columns, rows: rows)
    }

    func closeTerminal(_ id: UUID) {
        Analytics.featureUsed(.terminalClosed)
        LastActivity.clear(id)
        activeSession?.closeTerminal(id)
    }
}

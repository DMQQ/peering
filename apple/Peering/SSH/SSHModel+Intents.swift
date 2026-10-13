import Foundation
import PeeringKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    /// Three answers because an intent cannot ask a question: with a shell open it goes there, with a stored credential it connects, with neither it hands the user to the screen that can ask. A stored key counts, so a shortcut to a key-only server does not open a password sheet.
    func openShellFromIntent(_ host: SSHHost) {
        // The list, not the last shell looked at: a question asked over somebody else's terminal is about the wrong machine.
        selectedTerminalID = nil
        // The lock is asked for here like anywhere: a Shortcut is a way in, not a way past.
        requestOpen(host)
    }

    /// The credential comes from the open shell, not the keychain: the user may not have asked to remember it, and asking again would make the second tab cost more. Nothing is stored.
    @discardableResult
    func openAnotherShell(on terminal: SSHTerminal) -> SSHTerminal {
        // Deliberately not through `requestOpen(_:)` and so not past a lock: this is the second shell on a machine already in view.
        open(terminal.host, credential: terminal.credential, remember: false)
    }

    /// The representative name comes from the most recently opened live shell, so a second server does not rename the card away from the one in view.
    func syncTerminalActivity() {
        let live = openShells
        guard !live.isEmpty else {
            TerminalActivity.shared.end()
            return
        }
        let name = live.last!.host.displayName
        let startedAt = live.compactMap { t -> Date? in
            if case .live = t.phase { return t.startedAt } else { return nil }
        }.min()
        TerminalActivity.shared.update(serverName: name, startedAt: startedAt, shellCount: live.count)
    }

    func trimMemory() {
        for terminal in terminals { terminal.trimForMemoryPressure() }
    }

    func closeAllShells() {
        refuseKeyPrompts()
        for terminal in terminals {
            terminal.session.close()
        }
        terminals.removeAll()
        selectedTerminalID = nil
        TerminalActivity.shared.end()
        // Every host: the loop above dropped every shell at once, so there is no "last one" per machine.
        let hosts = forwarders.keys
        Task { @MainActor in
            for host in hosts { await self.stopForwards(on: host) }
        }
        hostSessions.removeAll()
    }
}

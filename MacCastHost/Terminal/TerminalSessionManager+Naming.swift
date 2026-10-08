import Darwin
import Foundation
import RemoteCore
import os

extension TerminalSessionManager {
    /// Puts a new name on a terminal, if it will take one.
    func rename(id: UUID, ownerClientID: String, to requested: String, isManual: Bool) {
        let updated: TerminalSessionInfo? = lock.withLock {
            guard let session = sessions[id], session.ownerClientID == ownerClientID else { return nil }
            let name = sanitizedName(requested)
            if isManual {
                session.manualName = name.isEmpty ? nil : name
            } else {
                guard !name.isEmpty else { return nil }
                session.lastCommand = name
            }
            let resolved = session.manualName
                ?? session.lastCommand
                ?? unusedTerminalName(excluding: session)
            guard resolved != session.name else { return nil }
            session.name = resolved
            return session.info
        }
        guard let updated else { return }
        send(.renamed(updated), to: ownerClientID)
        terminalLog.notice("renamed terminal to \(updated.name, privacy: .public)")
    }

    /// The lowest "Terminal N" that no live terminal is using.
    func unusedTerminalName(excluding excluded: Session? = nil) -> String {
        let taken = Set(sessions.values.filter { $0 !== excluded }.map(\.name))
        var number = 1
        while taken.contains("Terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }

    func sanitizedName(_ requested: String) -> String {
        let safe = String(requested.filter { character in
            !character.isNewline && !character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        }.prefix(40))
        return safe.trimmingCharacters(in: .whitespaces)
    }

    func loginShell() -> String {
        if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

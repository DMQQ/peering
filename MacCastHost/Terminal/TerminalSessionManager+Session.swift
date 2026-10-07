import Darwin
import Foundation
import RemoteCore
import os

extension TerminalSessionManager {
    final class Session: @unchecked Sendable {
        let id: UUID
        let ownerClientID: String
        let createdAt = Date()
        var name: String
        let process: Process
        let master: FileHandle
        var isRunning = true
        var history = Data()
        /// The shape its screen was last told it is, starting at what ``openpty`` was given.
        var columns = 100
        var rows = 30
        var attentionDetector = TerminalAttentionDetector()
        var finishDetector = TerminalCommandFinishDetector()
        var manualName: String?
        var lastCommand: String?

        init(id: UUID, ownerClientID: String, name: String, process: Process, master: FileHandle) {
            self.id = id
            self.ownerClientID = ownerClientID
            self.name = name
            self.process = process
            self.master = master
        }

        var info: TerminalSessionInfo {
            TerminalSessionInfo(
                id: id,
                name: name,
                isRunning: isRunning,
                columns: columns,
                rows: rows,
                createdAt: createdAt
            )
        }
    }
}

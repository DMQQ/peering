import PeeringKit
import RemoteCore

extension MacSession {
    private static let pressureTerminalBytes = 32 * 1024
    private static let pressureLogLines = 10

    /// Drops what can be had again or was only scrollback: old terminal output, the session log, the older turns of each conversation.
    func trimMemory() {
        for index in terminals.indices {
            terminals[index].trimOutput(keeping: Self.pressureTerminalBytes)
        }
        if activeSessionLogs.count > Self.pressureLogLines {
            activeSessionLogs.removeFirst(activeSessionLogs.count - Self.pressureLogLines)
        }
        for index in agentSessions.indices {
            agentSessions[index].transcript.trimForMemoryPressure()
        }
    }
}

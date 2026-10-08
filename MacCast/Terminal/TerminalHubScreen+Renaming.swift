import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    func beginRename(_ terminal: TerminalCardDigest) {
        renameText = terminal.name
        renaming = .terminal(terminal.id)
    }

    func beginRename(_ session: AgentCardDigest) {
        renameText = session.title
        renaming = .chat(session.id)
    }

    func commitRename() {
        guard let renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch renaming {
        case .terminal(let id): model.renameTerminal(id, to: name)
        case .chat(let id): model.renameAgentSession(id, to: name)
        }
        self.renaming = nil
    }

    var pendingEndName: String {
        switch pendingEnd {
        case .terminal(let id): return model.terminalCards.first { $0.id == id }?.name ?? ""
        case .chat(let id): return model.agentCards.first { $0.id == id }?.title ?? ""
        case nil: return ""
        }
    }

    var pendingEndDetail: String {
        switch pendingEnd {
        case .terminal:
            return String(localized: "The shell running in it stops. Your Mac and the rest of the terminals are left alone.")
        case .chat:
            return String(localized: "The agent stops working on your Mac. The Mac and the rest of the chats are left alone.")
        case nil:
            return ""
        }
    }

    func endPending() {
        switch pendingEnd {
        case .terminal(let id): model.closeTerminal(id)
        case .chat(let id): model.closeAgentSession(id)
        case nil: break
        }
        pendingEnd = nil
    }
}

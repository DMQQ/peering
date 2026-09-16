import RemoteCore
import SwiftUI

/// Terminals: the events the Mac sends, and the requests the phone makes.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension SessionModel {
    func refreshTerminals() { session?.sendTerminal(.list) }

    func createTerminal(name: String) {
        session?.sendTerminal(.create(name: name))
    }

    func selectTerminal(_ id: UUID) {
        selectedTerminalID = id
        if let index = terminals.firstIndex(where: { $0.id == id }) { terminals[index].attention = nil }
    }

    func sendTerminalInput(_ text: String, to id: UUID, appendReturn: Bool = true) {
        let suffix = appendReturn ? "\r" : ""
        guard let data = (text + suffix).data(using: .utf8) else { return }
        session?.sendTerminal(.input(sessionID: id, data: data))
        if let index = terminals.firstIndex(where: { $0.id == id }) { terminals[index].attention = nil }
    }

    func sendTerminalBytes(_ bytes: [UInt8], to id: UUID) {
        session?.sendTerminal(.input(sessionID: id, data: Data(bytes)))
    }

    func resizeTerminal(_ id: UUID, columns: Int, rows: Int) {
        session?.sendTerminal(.resize(
            sessionID: id,
            columns: UInt16(clamping: columns),
            rows: UInt16(clamping: rows)
        ))
    }

    func closeTerminal(_ id: UUID) {
        session?.sendTerminal(.close(sessionID: id))
    }

    func apply(terminal event: TerminalEvent) {
        switch event {
        case .snapshot(let infos):
            terminals = infos.map {
                RemoteTerminal(id: $0.id, name: $0.name, isRunning: $0.isRunning)
            }
            if selectedTerminalID == nil || !terminals.contains(where: { $0.id == selectedTerminalID }) {
                selectedTerminalID = terminals.first?.id
            }
        case .created(let info):
            terminals.removeAll { $0.id == info.id }
            terminals.append(RemoteTerminal(id: info.id, name: info.name, isRunning: info.isRunning))
            selectedTerminalID = info.id
            append(note: "Terminal “\(info.name)” opened")
        case .output(let id, let data):
            guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
            terminals[index].output.append(data)
            let limit = 512 * 1024
            if terminals[index].output.count > limit {
                terminals[index].output.removeFirst(terminals[index].output.count - limit)
            }
        case .attention(let id, let kind, let message):
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].attention = kind
            }
            selectedTerminalID = id
            append(note: message)
            notifier.terminalNeedsAttention(message, sessionID: id)
        case .exited(let id, let status):
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].isRunning = false
            }
            append(note: "Terminal exited with status \(status)")
        case .closed(let id):
            let name = terminals.first(where: { $0.id == id })?.name ?? "Terminal"
            terminals.removeAll { $0.id == id }
            if selectedTerminalID == id { selectedTerminalID = terminals.first?.id }
            append(note: "\(name) closed")
        case .failed(_, let message):
            append(note: "Terminal: \(message)")
        }
    }

}

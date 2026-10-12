import Foundation
import MacCastKit
import RemoteCore

extension HostWireText {
    /// The event with every sentence the Mac wrote put into the phone's language.
    static func localized(_ event: TerminalEvent) -> TerminalEvent {
        switch event {
        case .attention(let id, let kind, let message):
            .attention(sessionID: id, kind: kind, message: localized(message))
        case .transferFailure(let id, let path, let message):
            .transferFailure(sessionID: id, path: path, message: localized(message))
        case .browseFailure(let id, let path, let message):
            .browseFailure(sessionID: id, path: path, message: localized(message))
        case .writeFailure(let id, let path, let message):
            .writeFailure(sessionID: id, path: path, message: localized(message))
        case .fileOperationDone(let id, let path, let note):
            .fileOperationDone(sessionID: id, path: path, note: localized(note))
        case .fileOperationFailure(let id, let path, let message):
            .fileOperationFailure(sessionID: id, path: path, message: localized(message))
        case .failed(let id, let message):
            .failed(sessionID: id, message: localized(message))
        default:
            event
        }
    }

    static func localized(_ event: AgentEvent) -> AgentEvent {
        switch event {
        case .browseFailure(let path, let message):
            .browseFailure(path: path, message: localized(message))
        case .browseWaiting(let path, let message):
            .browseWaiting(path: path, message: localized(message))
        case .failed(let id, let message):
            .failed(sessionID: id, message: localized(message))
        default:
            event
        }
    }

    static func patternedNote(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(in: text, template: "created folder %@") {
            return String(localized: "created folder \(found[0])")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "created file %@") {
            return String(localized: "created file \(found[0])")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "renamed %@ to %@") {
            return String(localized: "renamed \(found[0]) to \(found[1])")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "moved %@ to the Trash") {
            return String(localized: "moved \(found[0]) to the Trash")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "moved %@ and %@ more to the Trash"), let more = Int(found[1]) {
            return String(localized: "moved \(found[0]) and \(more) more to the Trash")
        }
        return nil
    }
}

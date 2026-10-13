import Foundation
import RemoteCore

/// What one client has pressed and not yet let go, so that leaving releases that and nothing another client holds.
public struct HeldInputLedger: Sendable, Equatable {
    private var buttons: [MouseButton] = []
    private var keys: [UInt16] = []

    public init() {}

    public var isEmpty: Bool { buttons.isEmpty && keys.isEmpty }

    public mutating func observe(_ command: RemoteCommand) {
        switch command {
        case .mouseDown(let button):
            if !buttons.contains(button) { buttons.append(button) }
        case .mouseUp(let button):
            buttons.removeAll { $0 == button }
        case .keyDown(let keyCode, _):
            if !keys.contains(keyCode) { keys.append(keyCode) }
        case .keyUp(let keyCode, _):
            keys.removeAll { $0 == keyCode }
        default:
            break
        }
    }

    /// The commands that undo what is held, newest first, leaving the ledger empty.
    public mutating func releaseCommands() -> [RemoteCommand] {
        defer {
            buttons.removeAll()
            keys.removeAll()
        }
        let keyReleases = keys.reversed().map { RemoteCommand.keyUp(keyCode: $0, modifiers: []) }
        let buttonReleases = buttons.reversed().map { RemoteCommand.mouseUp(button: $0) }
        return keyReleases + buttonReleases
    }
}

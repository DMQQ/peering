import Foundation
import Observation
import SSHCore
import SwiftUI

/// The commands the user keeps one tap away, in every terminal.
///
/// One list rather than one per terminal, because "a command I run often" is not a property of
/// which machine it runs on. Someone who reaches for `docker ps` on a server reaches for it on
/// their Mac too, and two lists would be two lists to maintain, with the one you are not looking
/// at being the one that is missing the command you want.
///
/// The type it stores is ``SSHQuickCommand``, which is named for where it was born rather than
/// for what it is — a string, a name, and a store. It lives in `SSHCore` because that is where it
/// was written, and the *one* thing it deliberately is not is the app's `Macro`, which is a macOS
/// virtual keycode and means nothing to a shell on the far end of anything.
@Observable
@MainActor
final class QuickCommands {
    private(set) var all: [SSHQuickCommand] = []

    private let store = SSHQuickCommandStore()

    init() {
        all = store.load()
    }

    func save(_ command: SSHQuickCommand) {
        all.removeAll { $0.id == command.id }
        all.append(command)
        store.save(all)
    }

    func delete(_ command: SSHQuickCommand) {
        all.removeAll { $0.id == command.id }
        store.save(all)
    }
}

// The saved commands used to be drawn here, as a strip of their own above the keys. They are now
// the leading chips of ``TerminalDeck``, which is the one row both of them share — see there for
// why two strips became one.

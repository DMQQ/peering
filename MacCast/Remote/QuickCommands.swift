import Foundation
import Observation
import SSHCore
import SwiftUI

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

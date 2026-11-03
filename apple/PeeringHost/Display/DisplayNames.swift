import CoreGraphics
import Foundation

final class DisplayNames: @unchecked Sendable {
    private struct Entry {
        var name: String
        let isPhoneManaged: Bool
    }

    private let lock = NSLock()
    private var entries: [CGDirectDisplayID: Entry] = [:]

    func record(_ displayID: CGDirectDisplayID, name: String, isPhoneManaged: Bool) {
        lock.withLock { entries[displayID] = Entry(name: name, isPhoneManaged: isPhoneManaged) }
    }

    func record(_ displayID: CGDirectDisplayID, name: String) {
        lock.withLock {
            guard let entry = entries[displayID] else { return }
            entries[displayID] = Entry(name: name, isPhoneManaged: entry.isPhoneManaged)
        }
    }

    func forget(_ displayID: CGDirectDisplayID) {
        lock.withLock { entries[displayID] = nil }
    }

    func name(for displayID: CGDirectDisplayID) -> String? {
        lock.withLock { entries[displayID]?.name }
    }

    func isPhoneManaged(_ displayID: CGDirectDisplayID) -> Bool {
        lock.withLock { entries[displayID]?.isPhoneManaged == true }
    }
}

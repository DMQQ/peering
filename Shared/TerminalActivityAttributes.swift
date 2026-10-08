import ActivityKit
import Foundation

nonisolated struct TerminalActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var serverName: String
        /// When the first shell became live, so a second shell does not reset the clock and losing one does not make the other look newer. Nil until any shell has connected.
        var startedAt: Date?
        var shellCount: Int
    }

    enum Phase: String, Codable, Hashable {
        case connecting
        case live
    }
}

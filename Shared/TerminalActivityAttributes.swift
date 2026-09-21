import ActivityKit
import Foundation

/// The Live Activity's shape for SSH terminal sessions, compiled into both the app and the widget.
///
/// Same reasoning as ``SessionActivityAttributes``: ActivityKit decodes the state the app wrote
/// using the widget's configuration, and they agree only because they are the same declaration.
/// `nonisolated` for the reason ``SessionActivityAttributes`` gives from the other direction.
nonisolated struct TerminalActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// The display name of the server the most recently opened shell connects to.
        var serverName: String
        /// When the first shell became live. Nil until any shell has connected.
        ///
        /// Anchored to the earliest live shell so the timer keeps the right time across opens and
        /// closes: a second shell on the same session does not reset the clock, and losing a shell
        /// does not make the remaining one look newer than it is.
        var startedAt: Date?
        /// How many shells are open.
        var shellCount: Int
    }

    enum Phase: String, Codable, Hashable {
        case connecting
        case live
    }
}

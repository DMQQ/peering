import Foundation

/// The routes a session tried, in order, and how each came out, for one analytics string such as `lan:timedOut,relay:ok`. Routes and outcomes are closed sets: never an address, a name or an id.
public struct RouteAttemptLog: Sendable, Equatable {
    public enum Route: String, Sendable {
        case lan, relay, address
    }

    private struct Attempt: Equatable {
        let route: Route
        var outcome: String?
    }

    /// A flapping session would otherwise grow the string without end.
    public static let capacity = 6

    public static let succeeded = "ok"

    private var attempts: [Attempt] = []

    public init() {}

    public mutating func begin(_ route: Route) {
        attempts.append(Attempt(route: route, outcome: nil))
        if attempts.count > Self.capacity { attempts.removeFirst(attempts.count - Self.capacity) }
    }

    /// Settles the newest attempt on `route` that has no outcome. A second report for the same attempt changes nothing.
    public mutating func finish(_ route: Route, outcome: String) {
        guard let index = attempts.lastIndex(where: { $0.route == route && $0.outcome == nil }) else { return }
        attempts[index].outcome = outcome
    }

    public var summary: String {
        attempts.map { "\($0.route.rawValue):\($0.outcome ?? "pending")" }.joined(separator: ",")
    }
}

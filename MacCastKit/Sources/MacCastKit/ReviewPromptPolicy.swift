import Foundation

/// When the app may ask for an App Store rating. Only after the user has finished several real sessions over several days, so the ask lands on someone who has got value out of the app.
public struct ReviewPromptPolicy: Sendable {
    public struct Tally: Codable, Equatable, Sendable {
        public var qualifyingSessions = 0
        public var firstQualifyingAt: Date?
        public var lastAskedAt: Date?

        public init() {}

        public mutating func record(sessionDuration: TimeInterval, at date: Date) {
            guard sessionDuration >= ReviewPromptPolicy.minimumSessionDuration else { return }
            qualifyingSessions += 1
            if firstQualifyingAt == nil { firstQualifyingAt = date }
        }
    }

    /// Long enough to exclude a mistaken connect and a quick check.
    public static let minimumSessionDuration: TimeInterval = 120
    public static let minimumQualifyingSessions = 3
    public static let minimumDaysSinceFirstSession: TimeInterval = 3 * 86_400
    /// Well inside Apple's own cap of three prompts per 365 days, so the system never swallows an ask we spent.
    public static let minimumDaysBetweenAsks: TimeInterval = 120 * 86_400
    /// Longer than ``SessionOfferPolicy/offerAfterSessionDelay`` so a subscription offer decided at the same teardown is shown first and this one then finds the paywall open.
    public static let askAfterSessionDelay: TimeInterval = 1.6

    public static func isDue(
        _ tally: Tally,
        hasPaywallOpen: Bool,
        hasPendingOffer: Bool,
        now: Date
    ) -> Bool {
        guard !hasPaywallOpen, !hasPendingOffer else { return false }
        guard tally.qualifyingSessions >= minimumQualifyingSessions,
              let first = tally.firstQualifyingAt,
              now.timeIntervalSince(first) >= minimumDaysSinceFirstSession
        else { return false }
        if let last = tally.lastAskedAt, now.timeIntervalSince(last) < minimumDaysBetweenAsks {
            return false
        }
        return true
    }
}

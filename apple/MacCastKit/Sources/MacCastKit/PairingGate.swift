import Foundation

/// Who may have the Mac's one unauthenticated pairing prompt, and how often that may be asked for.
/// Confined to the host's server queue; every method takes the time so tests need no clock.
public struct PairingGate: Sendable {
    public enum Refusal: Sendable, Equatable {
        case anotherPairingInProgress
        case tooManyAttempts
    }

    public struct Limits: Sendable, Equatable {
        public var window: TimeInterval = 60
        public var attemptsPerAddress = 3
        public var attemptsInTotal = 10
        /// Longer than a person needs to compare six digits and click, so a connection that keeps the prompt without finishing cannot lock everyone else out.
        public var holdLimit: TimeInterval = 180

        public init() {}
    }

    private struct Attempt {
        let address: String
        let at: Date
    }

    private let limits: Limits
    private var holder: UUID?
    private var heldSince = Date.distantPast
    private var attempts: [Attempt] = []

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Takes the prompt for `session`, or says why it cannot have it. A session that already holds it keeps it without counting again.
    public mutating func claim(session: UUID, address: String, now: Date) -> Refusal? {
        if holder == session { return nil }
        if holder != nil { return .anotherPairingInProgress }

        let window = limits.window
        attempts.removeAll { now.timeIntervalSince($0.at) >= window }
        let fromAddress = attempts.filter { $0.address == address }.count
        guard fromAddress < limits.attemptsPerAddress, attempts.count < limits.attemptsInTotal else {
            return .tooManyAttempts
        }
        attempts.append(Attempt(address: address, at: now))
        holder = session
        heldSince = now
        return nil
    }

    public func holds(_ session: UUID) -> Bool {
        holder == session
    }

    /// Returns whether `session` was the holder, so only the session that owned the prompt reports it gone.
    @discardableResult
    public mutating func release(session: UUID) -> Bool {
        guard holder == session else { return false }
        holder = nil
        return true
    }

    /// The holder that has kept the prompt past its limit, freed here for the caller to end.
    public mutating func evictStaleHolder(now: Date) -> UUID? {
        guard let stale = holder, now.timeIntervalSince(heldSince) > limits.holdLimit else { return nil }
        holder = nil
        return stale
    }
}

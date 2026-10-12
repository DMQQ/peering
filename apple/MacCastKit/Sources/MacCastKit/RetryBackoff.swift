import Foundation

/// Waits between attempts that double, up to a ceiling, for a fetch that may fail because the network is briefly gone.
public struct RetryBackoff: Equatable, Sendable {
    public let firstDelay: Duration
    public let ceiling: Duration
    public let maximumRetries: Int

    public init(firstDelay: Duration = .seconds(2), ceiling: Duration = .seconds(30), maximumRetries: Int = 4) {
        self.firstDelay = firstDelay
        self.ceiling = ceiling
        self.maximumRetries = maximumRetries
    }

    /// The wait before retry number `retry`, counting from zero. `nil` once the retries are used up.
    public func delay(beforeRetry retry: Int) -> Duration? {
        guard retry >= 0, retry < maximumRetries else { return nil }
        let doubled = firstDelay * (1 << min(retry, 20))
        return min(doubled, ceiling)
    }
}

import Foundation

extension ContinuousClock.Instant {
    func addingTimeInterval(_ seconds: TimeInterval) -> ContinuousClock.Instant {
        advanced(by: .seconds(seconds))
    }
}

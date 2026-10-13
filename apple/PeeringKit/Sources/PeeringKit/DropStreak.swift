import Foundation
import RemoteCore

/// Counts sessions that ended the same bad way in a row, so a connection that comes up and dies again and again stops being put back on its own. Each pass costs relay time and no pass is any use.
public struct DropStreak: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case retry
        case stop
    }

    /// Three in a row: one drop is weather and two can be a roam, three is a pattern.
    public static let limit = 3
    /// A session that ran this long was working, whatever ended it.
    public static let stableRunSeconds: TimeInterval = 120
    /// Or one that kept a picture arriving for this long.
    public static let stablePictureSeconds: TimeInterval = 60

    public private(set) var count = 0

    public init(count: Int = 0) {
        self.count = count
    }

    /// For a session that had reached ready and then failed.
    public mutating func sessionEnded(
        reason: ClientSession.FailureReason, ranSeconds: TimeInterval, pictureSeconds: TimeInterval
    ) -> Verdict {
        guard Self.isSilentDrop(reason), !Self.isStable(ranSeconds: ranSeconds, pictureSeconds: pictureSeconds) else {
            count = 0
            return .retry
        }
        count += 1
        return count >= Self.limit ? .stop : .retry
    }

    /// A manual connect starts over.
    public mutating func reset() {
        count = 0
    }

    public static func isStable(ranSeconds: TimeInterval, pictureSeconds: TimeInterval) -> Bool {
        ranSeconds >= stableRunSeconds || pictureSeconds >= stablePictureSeconds
    }

    /// The two endings that say nothing about why: the Mac asking to stop, a refusal or a pin problem are not this.
    static func isSilentDrop(_ reason: ClientSession.FailureReason) -> Bool {
        switch reason {
        case .unresponsive, .unresponsiveAfterCheck, .transport: return true
        default: return false
        }
    }

    /// From the first picture to the last one: a picture that stopped at ten seconds does not count for the minute after it.
    public static func pictureSeconds(
        ranSeconds: TimeInterval, firstPictureMilliseconds: Int?, lastFrameAgeMilliseconds: Int?
    ) -> TimeInterval {
        guard let firstPictureMilliseconds else { return 0 }
        let silent = Double(lastFrameAgeMilliseconds ?? 0) / 1000
        return max(0, ranSeconds - Double(firstPictureMilliseconds) / 1000 - silent)
    }
}

import Foundation

public struct ClientSessionRecord: Codable, Identifiable, Equatable {
    public enum Path: String, Codable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"

        /// Not what is stored: localizing the raw value would rename records already on the phone.
        public var name: String {
            switch self {
            case .lan: return String(localized: "LAN")
            case .relay: return String(localized: "Relay")
            case .direct: return String(localized: "Direct")
            }
        }
    }

    public let id: UUID
    public let hostID: String?
    public let hostName: String
    public let startedAt: Date
    public let endedAt: Date
    public let path: Path
    public let videoBytesReceived: Int64
    public let logs: [String]

    /// Not a ``Path`` case: the relay meters splice time whether or not the picture went around it, so a session that punched still counts as `.relay`. Defaulted, so older records decode as did-not-punch.
    public var usedDirectPath: Bool = false

    /// The stretches the session was actually up. A put-back session's span covers minutes the relay is not splicing, and the relay charges against a bucket that turns over at the epoch day (`Relay/src/quota.rs`), so times are kept, not a total. See ``RelayAllowance/secondsUsed(records:windowStart:liveRelaySegments:)``. Defaulted; the decoder handles both older shapes.
    public let connectedSegments: [DateInterval]

    public var connectedSeconds: TimeInterval {
        connectedSegments.reduce(0) { $0 + max(0, $1.duration) }
    }

    public var disconnectedSeconds: TimeInterval { max(0, duration - connectedSeconds) }

    /// Compared in whole seconds, where the screen prints, so two rows never read the same.
    public var wasInterrupted: Bool {
        Int(duration.rounded()) != Int(connectedSeconds.rounded())
    }

    /// A drop and a deliberate end arrive as the same phase; this decides whether the next connection continues the record (a drop) or starts a new one (user ended). Defaulted to true: nothing was merged in records written before this existed.
    public let endedDeliberately: Bool

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public init(
        id: UUID,
        hostID: String?,
        hostName: String,
        startedAt: Date,
        endedAt: Date,
        path: Path,
        videoBytesReceived: Int64,
        logs: [String],
        usedDirectPath: Bool = false,
        connectedSegments: [DateInterval]? = nil,
        endedDeliberately: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.path = path
        self.videoBytesReceived = videoBytesReceived
        self.logs = logs
        self.usedDirectPath = usedDirectPath
        self.connectedSegments = connectedSegments ?? [.stretch(from: startedAt, to: endedAt)]
        self.endedDeliberately = endedDeliberately
    }

    private enum CodingKeys: String, CodingKey {
        case id, hostID, hostName, startedAt, endedAt, path, videoBytesReceived, logs
        case usedDirectPath, connectedSegments, endedDeliberately
    }

    /// A coding key must belong to a stored property, and the connected seconds are derived now. See the decoder.
    private enum LegacyCodingKeys: String, CodingKey {
        case connectedSeconds
    }

    /// Written out because the synthesized decoder requires non-optional properties even with defaults, so an older history would throw `keyNotFound`, and ``SessionHistoryStore/load()`` reads that as "nothing stored" and would empty the whole history on the first launch after an update.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        hostID = try values.decodeIfPresent(String.self, forKey: .hostID)
        hostName = try values.decode(String.self, forKey: .hostName)
        // Decoded into two names of their own, because the default below is the span between them.
        let began: Date = try values.decode(Date.self, forKey: .startedAt)
        let ended: Date = try values.decode(Date.self, forKey: .endedAt)
        startedAt = began
        endedAt = ended
        path = try values.decode(Path.self, forKey: .path)
        videoBytesReceived = try values.decode(Int64.self, forKey: .videoBytesReceived)
        logs = try values.decode([String].self, forKey: .logs)
        usedDirectPath = try values.decodeIfPresent(Bool.self, forKey: .usedDirectPath) ?? false
        // Three shapes: no field (one stretch end to end), total only (seconds placed at the end of the span), or the times.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let segments = try values.decodeIfPresent([DateInterval].self, forKey: .connectedSegments) {
            connectedSegments = segments
        } else if let total = try legacy.decodeIfPresent(TimeInterval.self, forKey: .connectedSeconds) {
            connectedSegments = [.stretch(from: ended.addingTimeInterval(-max(0, total)), to: ended)]
        } else {
            connectedSegments = [.stretch(from: began, to: ended)]
        }
        endedDeliberately = try values.decodeIfPresent(Bool.self, forKey: .endedDeliberately) ?? true
    }
}

/// A reconnect continues the record a drop filed (same `id` and start, bytes and log carried), so the gap is all the span picks up. The record stays in the history meanwhile because iOS may kill the app before ``finishSessionHistory()`` runs. Only the newest record for the same Mac, not user-ended, on the same path: a record is metered by path and connected time together, so mixing LAN and relay minutes would mischarge.
public struct SessionContinuation: Equatable {
    public let id: UUID
    public let startedAt: Date
    public let connectedSegments: [DateInterval]
    public let videoBytesReceived: Int64
    public let logs: [String]

    /// Combined with OR: a session whose first half punched is a session it worked in.
    public let usedDirectPath: Bool

    public init(
        id: UUID,
        startedAt: Date,
        connectedSegments: [DateInterval] = [],
        videoBytesReceived: Int64 = 0,
        logs: [String] = [],
        usedDirectPath: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.connectedSegments = connectedSegments
        self.videoBytesReceived = videoBytesReceived
        self.logs = logs
        self.usedDirectPath = usedDirectPath
    }

    private init(_ record: ClientSessionRecord) {
        self.init(
            id: record.id,
            startedAt: record.startedAt,
            connectedSegments: record.connectedSegments,
            videoBytesReceived: record.videoBytesReceived,
            logs: record.logs,
            usedDirectPath: record.usedDirectPath
        )
    }

    /// History is newest first, so the first match is the newest, and a deliberate end stops the search rather than being looked past.
    public static func continued(
        in history: [ClientSessionRecord],
        hostID: String?,
        path: ClientSessionRecord.Path
    ) -> SessionContinuation? {
        // `nil == nil` would match every record from a session that never reached a handshake.
        guard let hostID else { return nil }
        guard let record = history.first(where: { $0.hostID == hostID }) else { return nil }
        guard !record.endedDeliberately, record.path == path else { return nil }
        return SessionContinuation(record)
    }

    /// Keeps the continuation's identity and start and adds the ending stretch; the span's start puts the gap on the row and keeps it out of the meter.
    public func filed(
        endedAt: Date,
        segmentStartedAt: Date,
        path: ClientSessionRecord.Path,
        hostID: String?,
        hostName: String,
        segmentBytes: Int64,
        logs: [String],
        usedDirectPath: Bool,
        endedDeliberately: Bool
    ) -> ClientSessionRecord {
        ClientSessionRecord(
            id: id,
            hostID: hostID,
            hostName: hostName,
            startedAt: startedAt,
            endedAt: endedAt,
            path: path,
            videoBytesReceived: videoBytesReceived + segmentBytes,
            logs: logs,
            usedDirectPath: usedDirectPath || self.usedDirectPath,
            // One more stretch, never a total, placed where it happened for the meter's window.
            connectedSegments: connectedSegments + [.stretch(from: segmentStartedAt, to: endedAt)],
            endedDeliberately: endedDeliberately
        )
    }
}

extension DateInterval {
    /// The phone's clock is corrected mid-session, so a start can arrive after its own end; such an interval would subtract from the allowance.
    static func stretch(from start: Date, to end: Date) -> DateInterval {
        DateInterval(start: min(start, end), end: end)
    }
}

/// The relay charges every connection a client ID opens to one counter, so this sums finished records and every live session.
public enum RelayAllowance {
    /// Seconds the relay is charging for in the window starting at `windowStart`. Only relayed sessions count: LAN spends nothing, and a punched direct path still spends because the relay splices the control channel. Counts the time inside the window, not sessions that began in it (see ``ClientSessionRecord/connectedSegments``).
    /// - Parameter liveRelaySegments: one stretch per live relay session, clipped the same way as finished ones.
    public static func secondsUsed(
        records: [ClientSessionRecord],
        windowStart: Date,
        liveRelaySegments: [DateInterval]
    ) -> TimeInterval {
        let window = DateInterval(start: windowStart, duration: windowLength)
        let recorded = records
            .filter { $0.path == .relay }
            .reduce(0) { total, record in
                total + record.connectedSegments.reduce(0) { $0 + overlap(of: $1, with: window) }
            }
        return recorded + liveRelaySegments.reduce(0) { $0 + overlap(of: $1, with: window) }
    }

    public static func secondsRemaining(
        allowance: TimeInterval?,
        records: [ClientSessionRecord],
        windowStart: Date,
        liveRelaySegments: [DateInterval]
    ) -> TimeInterval? {
        guard let allowance else { return nil }
        return max(0, allowance - secondsUsed(
            records: records,
            windowStart: windowStart,
            liveRelaySegments: liveRelaySegments
        ))
    }

    /// The relay's own number: `WINDOW_SECS` in `Relay/src/quota.rs`, one day.
    public static let windowLength: TimeInterval = 24 * 3_600

    /// Never negative, so a stretch outside the window takes nothing off the allowance.
    private static func overlap(of stretch: DateInterval, with window: DateInterval) -> TimeInterval {
        let began = max(stretch.start, window.start)
        let ended = min(stretch.end, window.end)
        return max(0, ended.timeIntervalSince(began))
    }

    /// Epoch seconds divided into days, as `Relay/src/quota.rs` does, so the meter and the server's counter turn over together.
    public static func windowNumber(at moment: Date) -> Double {
        (moment.timeIntervalSince1970 / windowLength).rounded(.down)
    }

    /// Not `startOfDay`, which agrees only in UTC: against local midnight the bar would show a fresh allowance while the relay still refuses.
    public static func windowStart(windowNumber: Double) -> Date {
        Date(timeIntervalSince1970: windowNumber * windowLength)
    }
}

/// What the relay said was left in the day's window when it set up a session. It is the relay's own counter, so it outranks the phone's sum of session clocks.
public struct RelayRemainingReport: Equatable, Sendable {
    public let seconds: TimeInterval
    public let receivedAt: Date

    public init(seconds: TimeInterval, receivedAt: Date) {
        self.seconds = seconds
        self.receivedAt = receivedAt
    }

    /// `nil` once the window has turned over, since the relay's counter reset and this number describes the last day.
    public func remaining(at moment: Date) -> TimeInterval? {
        guard RelayAllowance.windowNumber(at: receivedAt) == RelayAllowance.windowNumber(at: moment) else { return nil }
        return max(0, seconds - max(0, moment.timeIntervalSince(receivedAt)))
    }
}

public enum RelayTime {
    /// The hours form drops seconds: past an hour they are noise, and below it they matter as a session nears cut-off.
    public static func label(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(total % 60)s"
        }
        return "\(total)s"
    }
}

public enum SessionHistoryStore {
    private static let key = "Peering.sessionHistory"
    public static let visibleLimit = 25

    public static func load() -> [ClientSessionRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([ClientSessionRecord].self, from: data) else {
            return []
        }
        let kept = kept(decoded)
        if kept.count != decoded.count { save(kept) }
        return kept
    }

    public static func save(_ records: [ClientSessionRecord]) {
        guard let data = try? JSONEncoder().encode(kept(records)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// At most the newest twenty-five records, however many sessions the relay window holds: the history is stored on the phone and must not grow without bound. The relay reports the allowance left, so the phone's own tally is only a fallback.
    public static func kept(_ records: [ClientSessionRecord]) -> [ClientSessionRecord] {
        Array(records.prefix(visibleLimit))
    }
}

/// The twenty-sixth newer session removes the oldest record and its time and bytes, so these are not lifetime totals.
public struct SessionHistorySummary: Equatable, Sendable {
    public let sessionCount: Int
    public let connectedSeconds: TimeInterval
    public let videoBytes: Int64

    public init(records: [ClientSessionRecord]) {
        let visible = records.prefix(SessionHistoryStore.visibleLimit)
        sessionCount = visible.count
        connectedSeconds = visible.reduce(0) { $0 + $1.connectedSeconds }
        videoBytes = visible.reduce(0) { $0 + max(0, $1.videoBytesReceived) }
    }
}

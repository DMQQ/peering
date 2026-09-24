import Foundation

/// One completed connection, kept on this iPhone so Activity can explain what happened later.
public struct ClientSessionRecord: Codable, Identifiable, Equatable {
    public enum Path: String, Codable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"
    }

    public let id: UUID
    public let hostID: String?
    public let hostName: String
    public let startedAt: Date
    public let endedAt: Date
    public let path: Path
    public let videoBytesReceived: Int64
    public let logs: [String]

    /// Whether the picture took a path the two ends opened for themselves.
    ///
    /// A field of its own and deliberately not a ``Path`` case: the relay meters by how long it
    /// splices a session, whether or not the picture went around it, so a session that punched is
    /// still one the relay is charging for, and moving this onto ``path`` would take it off
    /// `.relay`. Defaulted, so a record written before this existed decodes as did-not-punch.
    public var usedDirectPath: Bool = false

    /// The stretches of the span the session was actually up for, which is not the whole span.
    ///
    /// A session the app puts back is one row from the first connect to the last disconnect, so its
    /// span covers minutes the relay is not splicing. The times and not a total, because the relay
    /// charges as it splices (`Relay/src/quota.rs`) against a bucket that turns over at the epoch
    /// day, so a session up across that turnover spends from two allowances. See
    /// ``RelayAllowance/secondsUsed(records:windowStart:liveRelaySegments:)``.
    ///
    /// Defaulted, and the decoder answers both shapes an older record can have.
    public let connectedSegments: [DateInterval]

    /// The total of those stretches, which is what a row shows.
    public var connectedSeconds: TimeInterval {
        connectedSegments.reduce(0) { $0 + max(0, $1.duration) }
    }

    /// Seconds of the span the session was not up for, which only a session the app put back has.
    public var disconnectedSeconds: TimeInterval { max(0, duration - connectedSeconds) }

    /// Whether the two figures are worth showing apart.
    ///
    /// The comparison is in whole seconds, which is where the screen prints: two figures that print
    /// the same second are one figure to the reader. Comparing the gap itself would round a
    /// half-second interruption to a whole second and print two rows reading the same thing.
    public var wasInterrupted: Bool {
        Int(duration.rounded()) != Int(connectedSeconds.rounded())
    }

    /// Whether the session ended because the user asked it to, rather than because it dropped.
    ///
    /// A drop and a deliberate end arrive as the same phase and are filed as the same record, and
    /// this is what decides whether the next connection to this Mac is the same session: the record
    /// a drop filed is continued by the reconnect that answers it, while the one the user ended is
    /// finished with. Without it, tapping Disconnect and coming back an hour later stays two rows.
    ///
    /// Defaulted to true, so a record written before this existed decodes as one the user ended:
    /// nothing was merged when those records were written.
    public let endedDeliberately: Bool

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    /// - Parameter connectedSegments: left out for a session that was never dropped, where the
    ///   answer is one stretch covering the span and there is nothing to say.
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

    /// The key of a field this type no longer writes and still reads.
    ///
    /// A container of its own, because a coding key has to belong to a stored property and the
    /// connected seconds are derived now. See the decoder.
    private enum LegacyCodingKeys: String, CodingKey {
        case connectedSeconds
    }

    /// Written out rather than synthesized, for the three fields this type has grown since records
    /// already existed.
    ///
    /// The synthesized decoder requires a non-optional property even when it has a default, so a
    /// history written by an earlier build would throw `keyNotFound`, and
    /// ``SessionHistoryStore/load()`` reads a decode failure as "nothing was stored": the whole
    /// history would empty itself on the first launch after an update.
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
        // Absent is "did not punch".
        usedDirectPath = try values.decodeIfPresent(Bool.self, forKey: .usedDirectPath) ?? false
        // Three answers. A record filed before the field existed has one stretch, connected from end
        // to end; one filed by the build that kept the total and not the times keeps its seconds to
        // the second, placed at the end of the span, which is where the last stretch of a session
        // that was put back is.
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

/// The record a session that came back goes on being.
///
/// A reconnect is the same session to the user and so it is to the history: the record a drop filed
/// is continued rather than a new one started, same `id` and start, its bytes and its log carried
/// forward, so the gap is the only thing the span picks up.
///
/// The record stays in the history rather than being lifted out while it is continued, because a
/// continued session very often does not end through ``finishSessionHistory()``: iOS kills a
/// backgrounded app, and a record taken out would take its minutes with it.
///
/// The rule is narrow: only the newest record for the same Mac, only one the user did not end, and
/// only if the picture is on the same path. A record is metered by its path and its connected time
/// together, so one covering LAN minutes and relay minutes under a single path would either charge
/// the relay for time it did not splice or lose time it did.
public struct SessionContinuation: Equatable {
    public let id: UUID
    public let startedAt: Date
    public let connectedSegments: [DateInterval]
    public let videoBytesReceived: Int64
    public let logs: [String]

    /// Whether the picture took a path the two ends opened for themselves at any point in the
    /// session this continues.
    ///
    /// Combined with OR rather than taken from the segment that ends last: a session whose first
    /// half punched is a session it worked in.
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

    /// The record a session that has just come back continues, or `nil` when it continues nothing.
    ///
    /// The history is newest first, so "the newest record for this Mac" is the first one found, and
    /// the one a deliberate end wrote is the end of the question rather than something to look past.
    ///
    /// - Parameter path: the path this attempt came back on. See the note on the type.
    public static func continued(
        in history: [ClientSessionRecord],
        hostID: String?,
        path: ClientSessionRecord.Path
    ) -> SessionContinuation? {
        // A Mac that never said which one it is has no records to claim: `nil == nil` would match
        // every record filed by a session that never reached a handshake.
        guard let hostID else { return nil }
        guard let record = history.first(where: { $0.hostID == hostID }) else { return nil }
        guard !record.endedDeliberately, record.path == path else { return nil }
        return SessionContinuation(record)
    }

    /// The record to file now that the session has ended, with this segment's own minutes and
    /// bytes added to what the continuation carried.
    ///
    /// The continuation's identity and start are kept, its stretches are the ones it carried plus
    /// the one ending now, and the span runs from the record's own start, which puts the gap on the
    /// row and keeps it out of the meter.
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
            // One more stretch, and never a total: the stretch just ended is placed where it
            // happened, which is what the meter's window needs. See
            // ``ClientSessionRecord/connectedSegments``.
            connectedSegments: connectedSegments + [.stretch(from: segmentStartedAt, to: endedAt)],
            endedDeliberately: endedDeliberately
        )
    }
}

extension DateInterval {
    /// One stretch, in the direction time runs.
    ///
    /// Every stretch of connected time is built through here. The phone's clock is corrected while
    /// sessions are running, so a start arriving after its own end happens rather than cannot, and
    /// an interval like that would subtract from the connected time and take seconds off somebody's
    /// allowance.
    static func stretch(from start: Date, to end: Date) -> DateInterval {
        DateInterval(start: min(start, end), end: end)
    }
}

/// The relay's allowance, counted over every session at once.
///
/// The relay charges every connection a client ID opens to one counter, so what is left is a sum
/// over the finished records and over every live session, not over the one session the app happens
/// to consider live.
public enum RelayAllowance {
    /// Seconds the relay is charging for in the window that began at `windowStart`.
    ///
    /// Only relayed sessions, live or finished: a session over the LAN spends nothing, and one that
    /// punched a direct path still spends the allowance, because the relay splices the control
    /// channel either way. That is why ``ClientSessionRecord/usedDirectPath`` is filed beside the
    /// path rather than folded into it.
    ///
    /// What is counted is the time inside the window, not the sessions that began in it: the relay
    /// charges a splice as it runs (`Relay/src/quota.rs`) against a bucket that turns over at the
    /// epoch day, so a session that started before the window and was still running after it began
    /// spends here exactly the part of itself that falls inside. See
    /// ``ClientSessionRecord/connectedSegments``.
    ///
    /// - Parameter liveRelaySegments: one stretch per session that is up on the relay now, each
    ///   from the moment it came up to this one. Clipped the same way, so a session is counted by
    ///   the same rule while it runs as after it ends.
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

    /// Seconds of the allowance left, or `nil` on a plan that has none to spend.
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

    /// How long the window is, which is the relay's own number: `WINDOW_SECS` in
    /// `Relay/src/quota.rs`, one day.
    public static let windowLength: TimeInterval = 24 * 3_600

    /// Seconds two stretches of time have in common, never a negative number, so a stretch outside
    /// the window takes nothing off somebody's allowance.
    private static func overlap(of stretch: DateInterval, with window: DateInterval) -> TimeInterval {
        let began = max(stretch.start, window.start)
        let ended = min(stretch.end, window.end)
        return max(0, ended.timeIntervalSince(began))
    }

    /// Which 24-hour window the relay is counting in: epoch seconds divided into days.
    ///
    /// The relay's own arithmetic rather than a calendar's, since `Relay/src/quota.rs` divides
    /// exactly this way, so the meter, the bar and the server's own counter turn over together.
    public static func windowNumber(at moment: Date) -> Double {
        (moment.timeIntervalSince1970 / windowLength).rounded(.down)
    }

    /// The start of the window the relay is counting against.
    ///
    /// Not `startOfDay`, which agrees only in UTC: the relay has no calendar, so a bar drawn against
    /// local midnight would show a fresh allowance while the relay was still refusing connections.
    public static func windowStart(windowNumber: Double) -> Date {
        Date(timeIntervalSince1970: windowNumber * windowLength)
    }
}

/// Relay time, spelled the way the app says it.
///
/// One spelling for the two screens that print it, the meter in the Sessions tab and the sentence at
/// the top of the paywall, so the same number cannot disagree with itself across them.
public enum RelayTime {
    /// A duration as hours and minutes, minutes and seconds, or seconds, whichever reads.
    ///
    /// The hours form drops the seconds deliberately: past an hour they are noise, and below an hour
    /// they are the whole of the useful figure, that being the range in which a session is about to
    /// be cut off.
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
    public static let visibleLimit = 20

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

    /// The twenty visible records, plus any extra records the current relay allowance still needs.
    /// A burst of short sessions must not make the meter forget minutes the relay is still billing.
    public static func kept(_ records: [ClientSessionRecord], at moment: Date = Date()) -> [ClientSessionRecord] {
        let windowStart = RelayAllowance.windowStart(windowNumber: RelayAllowance.windowNumber(at: moment))
        let visibleIDs = Set(records.prefix(visibleLimit).map(\.id))
        return records.filter { visibleIDs.contains($0.id) || $0.endedAt >= windowStart }
    }
}

/// What the bounded recent history adds up to.
///
/// These are deliberately not called lifetime totals: the twenty-first newer session removes the
/// oldest record, and its time and bytes leave the summary with it.
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

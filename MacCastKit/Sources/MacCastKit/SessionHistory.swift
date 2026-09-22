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
    /// **A field of its own, and deliberately not a ``Path`` case.** The relay meters by how long
    /// it splices a session, whether or not the picture went around it, so a session that punched
    /// is still a session the relay is charging for. Moving it onto ``path`` would take it off
    /// `.relay`, and `relaySecondsUsedThisPeriod` would stop counting a session that is still
    /// spending the allowance. The two facts look like one and are not.
    ///
    /// It is here at all because "did punching work, and how often" has been an opinion since the
    /// feature shipped, and a second relay region is supposed to be decided on the number rather
    /// than on the opinion. Defaulted, so a record written before this existed decodes as "did not
    /// punch", which is what the app believed at the time.
    public var usedDirectPath: Bool = false

    /// The stretches of the span the session was actually up for, which is not the whole span.
    ///
    /// **Where the time went, and not only how much of it there was.** A session the app puts back
    /// is one row from the first connect to the last disconnect, so its span covers the minutes the
    /// phone spent backgrounded, the ladder spent retrying and the Mac spent unreachable, and the
    /// relay is splicing none of that. The meter is the allowance, so a merged record summed by its
    /// span would charge a free user for the gap and cut them off early, on the one screen they
    /// would go to in order to find out why. One interval per stretch the session was up, then: a
    /// session that never dropped has one, and a resumed one has as many as it was put back.
    ///
    /// **The times and not the total, because the allowance is metered in windows.** The relay
    /// charges as it splices (`Relay/src/quota.rs`), against a bucket that turns over at the epoch
    /// day, so a session that was up across that turnover pays for its minutes either side of it
    /// out of two different allowances. A record that knew only how many connected seconds it had
    /// could not be told apart from one that spent them all yesterday, and the phone's bar would
    /// go on saying there was time left that the relay was never going to give. See
    /// ``RelayAllowance/secondsUsed(records:windowStart:liveRelaySegments:)``.
    ///
    /// Defaulted, and the two shapes a record written before this can have are both answered on the
    /// way in: a record from before any of it becomes one stretch covering everything it has, which
    /// is the truth about it, and one from the build that kept the total and not the times keeps
    /// that total exactly and has it placed at the end of the span. See the decoder.
    public let connectedSegments: [DateInterval]

    /// The total of those stretches, which is what a reader wants and what a row shows.
    public var connectedSeconds: TimeInterval {
        connectedSegments.reduce(0) { $0 + max(0, $1.duration) }
    }

    /// Seconds of the span the session was not up for, which only a session the app put back has.
    public var disconnectedSeconds: TimeInterval { max(0, duration - connectedSeconds) }

    /// Whether the two figures are worth showing apart.
    ///
    /// **The comparison is made where the screen prints, which is whole seconds.** Two figures that
    /// print the same second are one figure to the reader, and a second row reading the first one
    /// back is noise; two that print differently are two facts about the session, however close
    /// together they are, and hiding one of them would be the app keeping a number to itself.
    /// Nearly every record has them equal, because nearly every session was never dropped, and
    /// those are the rows that must not grow a line beneath them.
    ///
    /// Comparing the gap itself would be the near miss: a session interrupted for half a second
    /// rounds to one second of gap and would print two rows reading the same thing.
    public var wasInterrupted: Bool {
        Int(duration.rounded()) != Int(connectedSeconds.rounded())
    }

    /// Whether the session ended because the user asked it to, rather than because it dropped.
    ///
    /// Kept because a drop and a deliberate end arrive as the same phase and are filed as the same
    /// record, and the difference is the whole of what decides whether the next connection to this
    /// Mac is the same session or a new one: the record a drop filed is continued by the reconnect
    /// that answers it, and the session the user ended is finished with. Without it, tapping
    /// Disconnect and coming back an hour later would fold two sessions into one row.
    ///
    /// Defaulted, so a record written before this existed decodes as one the user ended. That is
    /// the conservative answer rather than a claim about the past: nothing was merged when those
    /// records were written, so each of them is a session on its own whatever ended it, and this
    /// is what keeps that true.
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
    /// **A container of its own, because a coding key has to belong to a stored property.** The
    /// connected seconds became the total of ``connectedSegments``, which is derived rather than
    /// stored, so the key they were written under has nothing left to name, and a decoder that
    /// listed it beside the others would take the synthesized encoder down with it. What it is
    /// still good for is a record filed by the build in between. See the decoder.
    private enum LegacyCodingKeys: String, CodingKey {
        case connectedSeconds
    }

    /// Written out rather than synthesized, for the three fields this type has grown since records
    /// already existed.
    ///
    /// **A non-optional property with a default is still required by the synthesized decoder.**
    /// `usedDirectPath` is a field this type grew after records already existed, so a history
    /// written by an earlier build has no key for it and decoding throws `keyNotFound`. That would
    /// not be a visible failure: ``SessionHistoryStore/load()`` reads a decode failure as "nothing
    /// was stored", so the whole thirty-session history would quietly empty itself on the first
    /// launch after an update. Five tests in `MacCastPolicyTests` hold this down, three of them
    /// decoding a record written without the keys.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        hostID = try values.decodeIfPresent(String.self, forKey: .hostID)
        hostName = try values.decode(String.self, forKey: .hostName)
        // Decoded into two names of their own, because the default below is the span between them
        // and reading the properties back for it would be reading `self` before it exists.
        let began: Date = try values.decode(Date.self, forKey: .startedAt)
        let ended: Date = try values.decode(Date.self, forKey: .endedAt)
        startedAt = began
        endedAt = ended
        path = try values.decode(Path.self, forKey: .path)
        videoBytesReceived = try values.decode(Int64.self, forKey: .videoBytesReceived)
        logs = try values.decode([String].self, forKey: .logs)
        // Absent is "did not punch", which is what the app believed before it could tell.
        usedDirectPath = try values.decodeIfPresent(Bool.self, forKey: .usedDirectPath) ?? false
        // **Three answers, and the older two are exact about what they can be.** A record filed
        // before this field existed has one stretch, connected from end to end, because nothing was
        // continued and nothing was metered in windows; a record filed by the build that kept the
        // total and not the times has its seconds preserved to the second, and where they fell is
        // answered by putting them at the end of the span, which is where the last stretch of a
        // session that was put back is.
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
/// **A reconnect is the same session to the user, and so it is to the history.** The app puts a
/// dropped session back on its own, and from the Mac's side nothing happened: the user backgrounded
/// their phone, iOS took the socket with it, and they came back to what they were doing. Filing a
/// second record for that is a Sessions tab claiming they connected twice to a Mac they never left,
/// which is exactly the reading the user objected to. So the record a drop filed is continued
/// rather than a new one started: same `id`, same start, its bytes and its log carried forward, and
/// the gap it covers is the only thing the span picks up.
///
/// **Not taken out of the history, which is the shape this could have had.** The record is the
/// app's only copy of the half of the session that has already happened, and the way a continued
/// session ends is very often *not* through ``finishSessionHistory()``: iOS kills a backgrounded
/// app, and a session that had been lifted out of the history would take its minutes with it. It
/// stays where it is (the Sessions tab showing one row for the whole of the session is the point)
/// and the session that continued it replaces it when it ends.
///
/// **The rule is deliberately narrow.** Only the newest record for the same Mac, only one the user
/// did not end, and only if the picture is on the same path. The first is what stops a reconnect
/// reaching past the session it answers to an older one; the second is what keeps a deliberate
/// Disconnect from folding two sessions into one row; and the third is money. A record is metered
/// by its path and its connected time together, so one covering LAN minutes and relay minutes under
/// a single path would either charge the relay for time it did not splice or lose time it did. A
/// Mac coming back on the other path is a second row, which is the price of the meter being honest.
public struct SessionContinuation: Equatable {
    public let id: UUID
    public let startedAt: Date
    public let connectedSegments: [DateInterval]
    public let videoBytesReceived: Int64
    public let logs: [String]

    /// Whether the picture took a path the two ends opened for themselves at any point in the
    /// session this continues.
    ///
    /// Carried and combined, rather than left to the segment that ends last: the field exists to
    /// say how often punching works, and a session whose first half punched and whose second half
    /// did not is a session it worked in.
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
    /// The history is newest first, which is how ``SessionHistoryStore`` keeps it and how the
    /// Sessions tab reads it, so "the newest record for this Mac" is the first one found; and the
    /// one a deliberate end wrote is the end of the question rather than something to look past.
    ///
    /// - Parameter path: the path this attempt came back on. See the note on the type.
    public static func continued(
        in history: [ClientSessionRecord],
        hostID: String?,
        path: ClientSessionRecord.Path
    ) -> SessionContinuation? {
        // A Mac that never said which one it is has no records to claim: `nil == nil` would match
        // every record filed by a session that never reached a handshake, which is every record
        // this app has never been able to attribute.
        guard let hostID else { return nil }
        guard let record = history.first(where: { $0.hostID == hostID }) else { return nil }
        guard !record.endedDeliberately, record.path == path else { return nil }
        return SessionContinuation(record)
    }

    /// The record to file now that the session has ended, with this segment's own minutes and
    /// bytes added to what the continuation carried.
    ///
    /// The arithmetic the whole file is about, in one place: the record keeps the continuation's
    /// identity and start, its stretches of connected time are the ones it carried plus the one
    /// ending now, and its span is the distance from the *record's* start, which is what puts the
    /// gap on the row and keeps it out of the meter.
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
            // **One more stretch, and never a total.** The stretch just ended is placed where it
            // happened, which is the whole of what the meter's window needs; the seconds are the
            // record's own sum of them. See ``ClientSessionRecord/connectedSegments``.
            connectedSegments: connectedSegments + [.stretch(from: segmentStartedAt, to: endedAt)],
            endedDeliberately: endedDeliberately
        )
    }
}

extension DateInterval {
    /// One stretch, in the direction time runs.
    ///
    /// **Every stretch of connected time is built through here.** The phone's clock is corrected
    /// while sessions are running, so a start that arrives after its own end is a thing that
    /// happens rather than a thing that cannot; without this it would file an interval whose
    /// duration subtracts from the session's own connected time, and the meter would take seconds
    /// off somebody's allowance for it.
    static func stretch(from start: Date, to end: Date) -> DateInterval {
        DateInterval(start: min(start, end), end: end)
    }
}

/// The relay's allowance, counted over every session at once.
///
/// **A rule and not app state, which is why it is here.** The relay charges every connection a
/// client ID opens to one counter, so what is left is a sum over the finished records *and* over
/// every live session — and getting that sum wrong is invisible until a user is cut off early or
/// told they have more time than they do. The app used to add the one session it considered live,
/// which was right while there could only be one and is wrong the moment there are two.
public enum RelayAllowance {
    /// Seconds the relay is charging for in the window that began at `windowStart`.
    ///
    /// Only relayed sessions, live or finished. A session over the LAN spends nothing, and one
    /// that punched a direct path for its picture still spends the allowance — the relay splices
    /// the control channel either way, which is what ``ClientSessionRecord/usedDirectPath`` is
    /// filed beside the path rather than folded into it for.
    ///
    /// **What is counted is the time inside the window, and not the sessions that began in it.**
    /// The relay charges a splice as it runs (`Relay/src/quota.rs`), against a bucket that turns
    /// over at the epoch day, so a session that was up across that turnover pays for its minutes
    /// on either side of it out of two different allowances, and the second of those is the one
    /// this is being asked about. A session that started before the window and was still running
    /// after it began therefore spends here exactly the part of itself that falls inside, which is
    /// what ``ClientSessionRecord/connectedSegments`` exists to make answerable. The old rule read
    /// the record's start and nothing else, which lost every minute a session spent on this side
    /// of a boundary it crossed, and told the user they had an allowance the relay had already
    /// spent.
    ///
    /// - Parameter liveRelaySegments: one stretch per session that is up on the relay now, each
    ///   from the moment it came up to this one. Clipped the same way, so that a session is
    ///   counted by the same rule while it runs as after it ends.
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

    /// Seconds two stretches of time have in common.
    ///
    /// `max(0, ...)` rather than a guard, so a stretch that ended before the window began and one
    /// that has not begun yet both come out as nothing rather than as a negative number of seconds
    /// subtracted from somebody's allowance.
    private static func overlap(of stretch: DateInterval, with window: DateInterval) -> TimeInterval {
        let began = max(stretch.start, window.start)
        let ended = min(stretch.end, window.end)
        return max(0, ended.timeIntervalSince(began))
    }

    /// Which 24-hour window the relay is counting in: epoch seconds divided into days.
    ///
    /// The relay's own arithmetic rather than a calendar's — `Relay/src/quota.rs` divides exactly
    /// this way — so the meter, the bar and the server's own counter all turn over at the same
    /// instant.
    public static func windowNumber(at moment: Date) -> Double {
        (moment.timeIntervalSince1970 / windowLength).rounded(.down)
    }

    /// The start of the window the relay is counting against.
    ///
    /// Deliberately not `startOfDay`, which is the same thing only in UTC. The relay has no
    /// calendar and does not know what time zone the phone is in, so a bar drawn against local
    /// midnight would show a fresh allowance while the relay was still refusing connections.
    public static func windowStart(windowNumber: Double) -> Date {
        Date(timeIntervalSince1970: windowNumber * windowLength)
    }
}

/// Relay time, spelled the way the app says it.
///
/// One spelling for the two screens that print it — the meter in the Sessions tab and the sentence
/// at the top of the paywall. "2h 41m left" on the card and "161 minutes left" on the sheet are the
/// same number disagreeing with itself, which is the drift the shared things in this app exist to
/// prevent; and the two are read within seconds of each other by anyone who taps through.
public enum RelayTime {
    /// A duration as hours and minutes, minutes and seconds, or seconds — whichever reads.
    ///
    /// The hours form drops the seconds deliberately. Past an hour they are noise, and a figure that
    /// ticks is one the eye goes back to; "2h 41m" is a level, and a level is what a reader deciding
    /// whether to stay connected needs. Below an hour they are the whole of the useful figure,
    /// because that is the range in which the session is about to be cut off rather than merely
    /// running long.
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
    private static let limit = 30

    public static func load() -> [ClientSessionRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ClientSessionRecord].self, from: data)) ?? []
    }

    public static func save(_ records: [ClientSessionRecord]) {
        let kept = Array(records.prefix(limit))
        guard let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

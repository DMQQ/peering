import Foundation

/// A session that has finished.
///
/// Kept because "how long was that, and what did it cost" is a question asked *after* the
/// session, and every number needed to answer it is only available while it is running. The
/// alternative is a live readout that vanishes the moment the phone disconnects, which is
/// exactly when someone would want to look at it.
struct HostSessionRecord: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let deviceName: String
    let started: Date
    let ended: Date

    /// Video payload bytes the host sent while this session was up.
    ///
    /// The stream's own count, not a per-device one: the encoder produces one stream and
    /// several clients share it, so bytes cannot honestly be divided between them. With the
    /// usual one phone attached they are the same number.
    let bytes: Int

    init(id: UUID = UUID(), deviceName: String, started: Date, ended: Date, bytes: Int) {
        self.id = id
        self.deviceName = deviceName
        self.started = started
        self.ended = ended
        self.bytes = bytes
    }

    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }

    /// `1h 04m`, `4m 12s`, `38s` — the coarsest unit that still says something.
    ///
    /// Seconds only matter on a short session and become noise on a long one; hours only matter
    /// on a long one and would read as `0h` on every short one.
    var durationDescription: String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    /// `4.2 MB`, `812 KB` — decimal units, because this is data over a network and every
    /// figure it will be compared against (bitrates, quotas) is decimal too.
    var bytesDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// `14:32` on the day it happened, or `Aug 3, 14:32` if that was not today.
    var startedDescription: String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(started) ? "HH:mm" : "d MMM, HH:mm"
        return formatter.string(from: started)
    }
}

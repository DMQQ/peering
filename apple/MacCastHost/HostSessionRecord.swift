import Foundation

struct HostSessionRecord: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let deviceName: String
    let started: Date
    let ended: Date

    let bytes: Int

    init(id: UUID = UUID(), deviceName: String, started: Date, ended: Date, bytes: Int) {
        self.id = id
        self.deviceName = deviceName
        self.started = started
        self.ended = ended
        self.bytes = bytes
    }

    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }

    var durationDescription: String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    var bytesDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    var startedDescription: String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(started) ? "HH:mm" : "d MMM, HH:mm"
        return formatter.string(from: started)
    }
}

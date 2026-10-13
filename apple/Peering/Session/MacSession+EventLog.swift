import Foundation
import PeeringKit
import RemoteCore

extension MacSession {
    /// A diagnostic line for the session log, stamped with the time it happened: where the connection went, why it dropped, what the phone was doing meanwhile. Kept before the session is ready too, so a failed attempt explains itself.
    func logEvent(_ line: String) {
        let stamped = Self.stamp(line)
        if activeSessionHistoryID != nil {
            activeSessionLogs.append(stamped)
            trim(&activeSessionLogs)
        } else {
            preReadyLogs.append(stamped)
            trim(&preReadyLogs)
        }
    }

    /// The notes shown as banners are filed in the log with their time as well.
    static func stamp(_ line: String, at moment: Date = Date()) -> String {
        let time = moment.formatted(.verbatim(
            "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: .current,
            calendar: .current
        ))
        return "\(time)  \(line)"
    }

    private func trim(_ lines: inout [String]) {
        if lines.count > Self.sessionLogLimit { lines.removeFirst(lines.count - Self.sessionLogLimit) }
    }

    func logPhase(_ phase: ClientSession.Phase) {
        let path = connectionPath.map { " over \($0.rawValue)" } ?? ""
        switch phase {
        case .idle: break
        case .connecting: logEvent("Connecting\(path)")
        case .handshaking: logEvent("Handshaking\(path)")
        case .confirming: logEvent("Waiting for the pairing code to be confirmed")
        case .ready: logEvent("Connected\(path)")
        case .failed(let message): logEvent("Failed: \(message)")
        case .disconnected: logEvent("Disconnected")
        }
    }

    func logHello(_ hello: ServerHello) {
        let platform = hello.hostPlatform ?? "unknown platform"
        logEvent("Host \(hello.hostName), protocol \(hello.protocolVersion), \(platform)")
    }
}

extension MacSession {
    /// One line a minute: enough to see a connection degrade over a session without a line per ping.
    func logLatencyIfDue(_ milliseconds: Double) {
        let now = Date()
        if let last = lastLatencyLogAt, now.timeIntervalSince(last) < 60 { return }
        lastLatencyLogAt = now
        logEvent("Latency \(Int(milliseconds.rounded())) ms")
    }
}

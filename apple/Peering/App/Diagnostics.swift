import PeeringKit
import RemoteCore
import UIKit

/// A paragraph about this install, for pasting into a message. The app has no analytics or crash reporting, so this copy button is the replacement: the user sees what is sent and decides.
/// Only versions, on-screen state and the device ID already shown in Settings; no Mac name, SSID or location.
enum Diagnostics {
    @MainActor
    static func text(model: SessionModel) -> String {
        var lines: [String] = []

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        lines.append("Peering \(version) (\(build))")
        lines.append("\(deviceModel()), iOS \(UIDevice.current.systemVersion)")
        lines.append("App version: \(ProtocolInfo.version) (the mobile and Mac apps must match)")
        lines.append("")

        let plan = model.storeManager.relayPlan
        lines.append("Plan: \(plan.rawValue)")
        lines.append("Relay allowed: \(model.allowsRelay ? "yes" : "no")")
        lines.append("Device ID: \(model.device.id)")
        lines.append("")

        lines.append("State: \(model.phase)")
        lines.append("Path: \(model.connectionPath.map { "\($0)" } ?? "none")")
        // Recorded beside the path: a session that found a direct path still has a relayed control connection, so this says which carried the picture.
        lines.append("Picture path: \(model.usedDirectPath ? "direct (peer to peer)" : "relay")")
        // How long the picture takes to come back after asking again: the figure the several-Macs design stands on, measurable only here. Read off the last session; "not measured" rather than omitted.
        let resume = model.activeSession?.lastResumeMilliseconds
        lines.append("Picture resume: \(resume.map { "\(Int($0.rounded())) ms" } ?? "not measured")")
        // From the last session rather than a live one, because Settings cannot open while a session runs.
        if let counts = model.datagramCounts {
            lines.append("Video datagrams: \(counts.summary)")
        }
        lines.append("Last failure: \(model.failureMessage ?? "none")")
        lines.append("Paired Macs: \(model.pairedHostIDs.count)")
        lines.append("Mac terminals open: \(model.terminals.count)")
        lines.append("")

        let recent = model.sessionHistory.prefix(3)
        if recent.isEmpty {
            lines.append("No sessions recorded yet.")
        } else {
            lines.append("Last \(recent.count) session(s):")
            for session in recent {
                lines.append("  \(format(session.startedAt)) · \(session.path) · \(format(session.duration)) · \(bytes(session.videoBytesReceived))")
            }
        }

        // Crashes are the part nobody can describe from memory. Bounded to the three most recent and the first frames of each.
        let crashes = CrashLog.entries(subject: "phone").prefix(3)
        lines.append("")
        if crashes.isEmpty {
            lines.append("No crashes recorded.")
        } else {
            lines.append("Last \(crashes.count) crash report(s):")
            for entry in crashes {
                lines.append("")
                lines.append("--- \(entry.kind.rawValue) · \(format(entry.date)) ---")
                let body = entry.text.split(separator: "\n", omittingEmptySubsequences: false)
                lines.append(contentsOf: body.prefix(Self.framesCarried).map(String.init))
                if body.count > Self.framesCarried {
                    lines.append("… \(body.count - Self.framesCarried) more lines in the report")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static let framesCarried = 40

    /// The hardware identifier: `UIDevice.model` says iPhone for every phone and `name` is the owner's own word for it.
    private static func deviceModel() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return UIDevice.current.model }
        let identifier = withUnsafeBytes(of: &system.machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

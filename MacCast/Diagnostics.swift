import MacCastKit
import RemoteCore
import UIKit

/// A paragraph about this install, for pasting into a message when something is wrong.
///
/// The app has no analytics and no crash reporting, which is a promise rather than an oversight —
/// so when something breaks there is nothing on this side to look at. This is the replacement for
/// that, and the reason it is a *copy* button rather than an automatic report: the user sees
/// exactly what is being sent, and decides whether to send it, which is what an app that says
/// "nothing is sent to us" has to mean.
///
/// It is written for the failure modes this app actually has. "It cannot connect" is usually a
/// protocol version mismatch or a relay problem, so both are on the first three lines. "The
/// picture is black" wants to know the path and the video state. "It says I am out of relay time"
/// wants the plan and the device ID, because the relay meters by device and that is the only
/// thing on this page the relay has ever seen.
///
/// Everything here is either a version number, a state the user can already see on screen, or the
/// device ID that the identity card in Settings already displays. There is no Mac name, no SSID,
/// no location, and no account — there isn't one.
enum Diagnostics {
    @MainActor
    static func text(model: SessionModel) -> String {
        var lines: [String] = []

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        lines.append("Peering \(version) (\(build))")
        lines.append("\(deviceModel()), iOS \(UIDevice.current.systemVersion)")
        // Named as what it is for rather than as what it is called: the number only ever matters
        // when the two apps disagree, and somebody reading this aloud needs to know that.
        lines.append("App version: \(ProtocolInfo.version) (the iPhone and Mac apps must match)")
        lines.append("")

        let plan = model.storeManager.relayPlan
        lines.append("Plan: \(plan.rawValue)")
        lines.append("Relay allowed: \(model.allowsRelay ? "yes" : "no")")
        lines.append("Device ID: \(model.device.id)")
        lines.append("")

        lines.append("State: \(model.phase)")
        lines.append("Path: \(model.connectionPath.map { "\($0)" } ?? "none")")
        // Recorded beside the path rather than folded into it: a session that found a path between
        // the two machines still has a relayed connection, because the relay goes on splicing its
        // control connection and metering it either way. This is the line that says which of the
        // two carried the picture.
        lines.append("Picture path: \(model.usedDirectPath ? "direct (peer to peer)" : "relay")")
        // **The figure the whole several-Macs-at-once design stands on.** How long the picture
        // takes to come back after this end asks for it again is the difference between switching
        // Macs and reconnecting to one, and it is measurable in exactly one place: the ask goes
        // out from here and the frames come back to the renderer, so this is the only code that
        // sees both ends of the interval. Read off the last session rather than a live one, like
        // the datagram counts above and for the same reason. "not measured" rather than omitted,
        // because a missing line reads as a feature that does not exist.
        let resume = model.activeSession?.lastResumeMilliseconds
        lines.append("Picture resume: \(resume.map { "\(Int($0.rounded())) ms" } ?? "not measured")")
        // Only for a session that had a datagram lane, and from the last one rather than the
        // live one, because Settings cannot be opened while a session is running. These are the
        // four figures that tell a lane the network is dropping from one this end is refusing,
        // and they are worth nothing once the counters have been reset by the next session.
        if let counts = model.datagramCounts {
            lines.append("Video datagrams: \(counts.summary)")
        }
        lines.append("Last failure: \(model.failureMessage ?? "none")")
        lines.append("Paired Macs: \(model.pairedHostIDs.count)")
        lines.append("Mac terminals open: \(model.terminals.count)")
        lines.append("")

        // The last few sessions, because "it drops after a while" is a question about a pattern
        // rather than about one connection, and the shape of the last three answers it.
        let recent = model.sessionHistory.prefix(3)
        if recent.isEmpty {
            lines.append("No sessions recorded yet.")
        } else {
            lines.append("Last \(recent.count) session(s):")
            for session in recent {
                lines.append("  \(format(session.startedAt)) · \(session.path) · \(format(session.duration)) · \(bytes(session.videoBytesReceived))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// The hardware identifier rather than the marketing name.
    ///
    /// `UIDevice.model` says "iPhone" for every phone ever made, and `name` is whatever the owner
    /// called it — which is a person's word for their own possession and none of our business.
    /// The identifier ("iPhone16,2") answers the question a report is asking, which is whether the
    /// hardware is special in some way.
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

import AppKit
import RemoteCore
import SwiftUI

/// A paragraph about this Mac's install of Peering, for pasting into a message.
///
/// The counterpart of the iPhone app's own copy button, and the more important of the two: the
/// failures this app has are Mac failures. A picture that is black, late or the wrong size is a
/// capture or encode problem here, a phone that cannot connect is usually a permission or a
/// listener here, and the first question anyone has to ask — "which app version, and does it have
/// Screen Recording?" — is answered on this page rather than after a round trip.
///
/// It reports the shape of the install and the last few things that happened. It does not report
/// what is on screen: the source is named by its kind and not by what it is showing, and the log
/// lines are the app's own.
enum HostDiagnostics {
    @MainActor
    static func text(model: HostModel) -> String {
        var lines: [String] = []

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        lines.append("Peering for Mac \(version) (\(build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Protocol version \(ProtocolInfo.version)")
        lines.append("")

        lines.append("Status: \(model.status.isListening ? "listening" : "not listening")")
        lines.append("Port: \(model.port)")
        lines.append("Device: \(model.deviceName)")
        lines.append("")

        // Permissions first among the state, because they are the answer to the most common
        // question by a wide margin — a Mac that is running and reachable and shows nothing is
        // almost always this.
        lines.append("Screen Recording: \(model.permissions.screenRecordingGranted ? "granted" : "NOT GRANTED")")
        lines.append("Accessibility: \(model.permissions.accessibilityGranted ? "granted" : "NOT GRANTED")")
        lines.append("")

        lines.append("Capture source: \(model.capturingSource.map(String.init(describing:)) ?? "none")")
        lines.append("Resolution: \(model.captureResolution.rawValue) · \(model.captureFrameRate.rawValue) fps · \(model.captureCodec.rawValue)")
        lines.append("Privacy mode: \(model.privacyModeEnabled ? "on" : "off")")
        lines.append("Paired devices: \(model.pairedClientIDs.count) · connected: \(model.connectedClients.count)")
        if !model.connectedClients.isEmpty {
            lines.append("Connected: \(model.connectedClients.map(\.name).joined(separator: ", "))")
        }
        lines.append("")

        // The tail of the log, which is where the answer usually is: a permission that was
        // revoked, a stream that failed to start, a client that hung up.
        let recent = model.log.suffix(6)
        if recent.isEmpty {
            lines.append("Log is empty.")
        } else {
            lines.append("Last \(recent.count) log line(s):")
            for entry in recent {
                lines.append("  \(entry.time) [\(entry.level)] \(entry.message)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// The About pane's copy button, with its own state for the same reason ``LaunchAtLoginRow`` has
/// its own: this is an extension of the window and cannot hold one.
struct HostDiagnosticsRow: View {
    let model: HostModel

    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(HostDiagnostics.text(model: model), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.large)
    }
}

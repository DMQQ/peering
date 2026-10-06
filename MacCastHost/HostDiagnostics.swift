import AppKit
import RemoteCore
import SwiftUI

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

import AppKit
import RemoteCore
import SwiftUI

extension HostStatusView {
    // MARK: - Sessions

    var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(String(localized: "Sessions"), detail: String(localized: "Finished connections, newest first."))

            if model.sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.callout)
                    .foregroundStyle(HostPalette.faint)
                    .padding(.vertical, 8)
            } else {
                sessionSummary

                VStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().padding(.leading, 14) }
                        sessionRow(session)
                    }
                }
                .hostPanel()

                Text("The summary and list cover the latest 20 sessions. Bytes are the video stream the host sent.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
            }
        }
    }

    private var sessionSummary: some View {
        HStack(spacing: 0) {
            sessionSummaryValue(String(localized: "Sessions"), "\(model.sessions.count)")
            Divider().frame(height: 34)
            sessionSummaryValue(String(localized: "Connected"), hostDuration(model.sessions.reduce(0) { $0 + $1.duration }))
            Divider().frame(height: 34)
            sessionSummaryValue(String(localized: "Video"), hostBytes(model.sessions.reduce(0) { $0 + Int64($1.bytes) }))
        }
        .padding(.vertical, 11)
        .hostPanel()
    }

    private func sessionSummaryValue(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(HostPalette.faint)
        }
        .frame(maxWidth: .infinity)
    }

    private func hostDuration(_ seconds: TimeInterval) -> String {
        TerminalCommandFinishDetector.spokenDuration(seconds)
    }

    private func hostBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func sessionRow(_ session: HostSessionRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HostPalette.faint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.deviceName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(session.startedDescription)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
            }

            Spacer(minLength: 12)

            Text(session.durationDescription)
                .font(.callout)
                .monospacedDigit()
            Text(session.bytesDescription)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(HostPalette.muted)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

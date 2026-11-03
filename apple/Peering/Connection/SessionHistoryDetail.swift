import PeeringKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

/// Cards on the app's backdrop rather than a `List`, whose own background, headers and insets read as stray iOS inside a near-black screen.
struct SessionHistoryDetail: View {
    let session: ClientSessionRecord

    @Environment(SessionModel.self) private var model

    @State private var copied = false

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Controls.card(String(localized: "Connection")) {
                        detailRow(String(localized: "Mac"), model.shownName(hostID: session.hostID, fallback: session.hostName))
                        Controls.divider
                        detailRow(String(localized: "Path"), session.path.name)
                        Controls.divider
                        detailRow(String(localized: "Started"), session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Controls.divider
                        detailRow(String(localized: "Duration"), durationLabel)
                        // The second figure, for sessions put back after a drop: the relay meter counts connected time, so without this row the duration and the allowance spent would disagree. Shown only when the two differ.
                        if session.wasInterrupted {
                            Controls.divider
                            detailRow(String(localized: "Connected"), connectedLabel)
                        }
                        Controls.divider
                        detailRow(
                            String(localized: "Video received"),
                            ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file)
                        )
                    }

                    Controls.card(String(localized: "Session log")) {
                        if session.logs.isEmpty {
                            Text("No diagnostic events were recorded for this session.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.logs.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle(model.shownName(hostID: session.hostID, fallback: session.hostName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Copied" : "Copy session log")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// The rows and the log together: a transport line means nothing without its session, and the version answers the first question asked about a failure.
    private var logText: String {
        var lines = [
            String(localized: "Peering session · \(model.shownName(hostID: session.hostID, fallback: session.hostName))"),
            String(localized: "App version: \(ProtocolInfo.version)"),
            String(localized: "Path: \(session.path.rawValue)"),
            String(localized: "Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"),
            String(localized: "Duration: \(durationLabel)"),
        ]
        if session.wasInterrupted { lines.append(String(localized: "Connected: \(connectedLabel)")) }
        lines.append(String(localized: "Video received: \(ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file))"))
        lines.append("")
        lines += session.logs.isEmpty
            ? [String(localized: "No diagnostic events were recorded for this session.")]
            : session.logs
        return lines.joined(separator: "\n")
    }

    private var durationLabel: String { secondsLabel(session.duration) }

    private var connectedLabel: String { secondsLabel(session.connectedSeconds) }

    private func secondsLabel(_ seconds: TimeInterval) -> String {
        spokenSeconds(seconds)
    }
}

private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(label)
            .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(value)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
    }
    .font(.subheadline)
}

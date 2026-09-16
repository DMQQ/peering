import AppKit
import RemoteCore
import SwiftUI

/// Who is trusted, who is here, and what has happened.
///
/// An extension on the window rather than a type of its own — the state is the
/// window's, and the window is easier to read in pieces than as one file of
/// fifteen hundred lines.
extension HostStatusView {
    /// On a wide window the compact device list sits beside the longer activity feed, making
    /// the overview an intentionally uneven dashboard. At the minimum window width it falls
    /// back to the familiar vertical reading order.
    var overviewLowerDeck: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                devicesSection.frame(width: 260, alignment: .topLeading)
                activitySection.frame(minWidth: 360, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 24) {
                devicesSection
                activitySection
            }
        }
    }

    /// Who is trusted, and which of them is here.
    ///
    /// The absent rows matter as much as the present ones. "Is that phone still allowed in" is
    /// a question asked when the phone is *not* on the desk, and a pin — which is all the host
    /// stores for a trusted device — carries no name, so an unattached device is named from the
    /// last time it connected.
    /// Who is trusted, and which of them is here.
    ///
    /// The absent rows matter as much as the present ones. "Is that phone still allowed in" is
    /// a question asked when the phone is *not* on the desk, and a pin — which is all the host
    /// stores for a trusted device — carries no name, so an unattached device is named from the
    /// last time it connected.
    var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Devices", detail: "Phones trusted to reach this Mac.")
                Spacer()
                if !model.pairedClientIDs.isEmpty {
                    Button("Forget all", role: .destructive) { model.unpairAll() }
                        .controlSize(.small)
                }
            }

            if model.pairedClientIDs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.title3)
                        .foregroundStyle(HostPalette.faint)
                    Text("No iPhones paired yet")
                        .font(.callout)
                        .foregroundStyle(HostPalette.muted)
                }
                .padding(.vertical, 8)
            } else {
                let connected = model.connectedClients
                let offline = model.pairedClientIDs.filter { !model.isConnected($0) }

                VStack(spacing: 0) {
                    ForEach(Array(connected.enumerated()), id: \.element.id) { index, client in
                        if index > 0 { Divider().padding(.leading, 44) }
                        deviceRow(
                            name: client.name,
                            id: client.id,
                            detail: "Connected · \(client.elapsedDescription())",
                            connected: true
                        )
                    }
                    ForEach(Array(offline.enumerated()), id: \.element) { index, id in
                        if index > 0 || !connected.isEmpty { Divider().padding(.leading, 44) }
                        deviceRow(
                            name: model.displayName(for: id),
                            id: id,
                            detail: "Trusted · not connected",
                            connected: false
                        )
                    }
                }
                .hostPanel()
            }
        }
    }

    func deviceRow(name: String, id: String, detail: String, connected: Bool) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(connected ? HostPalette.success.opacity(0.13) : HostPalette.raised)
                Image(systemName: connected ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(connected ? HostPalette.success : HostPalette.faint)
            }
            .frame(width: 36, height: 36)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(connected ? HostPalette.success.opacity(0.18) : HostPalette.hairline)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(connected ? HostPalette.success : HostPalette.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            if connected {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(HostPalette.success)
            }
            Button(role: .destructive) {
                forgetDevice = (id, name)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoveredDeviceID == id ? HostPalette.danger : HostPalette.faint)
            .help("Forget (name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            hoveredDeviceID == id ? HostPalette.raised : .clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .scaleEffect(hoveredDeviceID == id ? 1.004 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(HostMotion.hover) { hoveredDeviceID = hovering ? id : nil }
        }
        // The ID is what a pairing question turns on, so it stays reachable — as a tooltip
        // rather than as the thing printed on the row, where it was never what anyone
        // recognised.
        .help("Device ID \(id)")
    }

    /// A tail of what the host has done.
    ///
    /// Full width and below rather than a column of its own. These are sentences, and a narrow
    /// column wrapped every one of them into three lines to say what fitted on one.
    ///
    /// `Copy all` rather than leaving it to selection: the lines are separate text blocks, so
    /// dragging across them gets one line at a time — which is no way to hand anyone a run of
    /// events. The selection stays enabled for the single line someone wants to quote.
    /// A tail of what the host has done.
    ///
    /// Full width and below rather than a column of its own. These are sentences, and a narrow
    /// column wrapped every one of them into three lines to say what fitted on one.
    ///
    /// `Copy all` rather than leaving it to selection: the lines are separate text blocks, so
    /// dragging across them gets one line at a time — which is no way to hand anyone a run of
    /// events. The selection stays enabled for the single line someone wants to quote.
    var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Activity", detail: "Recent host events, newest last.")
                Spacer()
                if !model.log.isEmpty {
                    Button("Copy all") {
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(model.logText, forType: .string)
                    }
                    .controlSize(.small)
                    .help("Copies every line, with its timestamp")
                }
            }

            if model.log.isEmpty {
                HStack(spacing: 11) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(HostPalette.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for activity")
                            .font(.subheadline.weight(.medium))
                        Text("Connections, stream changes and problems will appear here.")
                            .font(.caption)
                            .foregroundStyle(HostPalette.faint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .padding(16)
                .hostPanel()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.enumerated()), id: \.element.id) { index, entry in
                            activityRow(entry)
                            if index < model.log.count - 1 {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 320)
                .hostPanel()
            }
        }
    }

    func activityRow(_ entry: HostLogEntry) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: entry.levelSymbol)
                .font(.system(size: entry.level == .info ? 7 : 13, weight: .semibold))
                .foregroundStyle(colour(for: entry.level))
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message)
                    .font(.system(size: 12.5, weight: entry.level == .info ? .regular : .medium))
                    .foregroundStyle(entry.level == .info ? HostPalette.ink : colour(for: entry.level))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(entry.time)
                        .monospacedDigit()
                    Text(entry.levelName)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HostPalette.faint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(entry.level == .failure ? HostPalette.danger.opacity(0.055) : .clear)
    }

    /// Three tones and no more: routine, worth noticing, did not work.
    ///
    /// The rest of the window keeps to brightness, but a failure is the one thing here a reader
    /// has to find by skimming, and losing it in grey is how a log stops being read at all.
    /// Three tones and no more: routine, worth noticing, did not work.
    ///
    /// The rest of the window keeps to brightness, but a failure is the one thing here a reader
    /// has to find by skimming, and losing it in grey is how a log stops being read at all.
    func colour(for level: HostLogEntry.Level) -> Color {
        switch level {
        case .info: return HostPalette.faint
        case .warning: return HostPalette.caution
        case .failure: return HostPalette.danger
        }
    }

    // MARK: - Sessions

    /// What has already happened, and what it cost.
    ///
    /// The live figures vanish the moment the phone disconnects — which is precisely when
    /// someone wants to look at them — so each finished session is written down as it ends.
    /// What has already happened, and what it cost.
    ///
    /// The live figures vanish the moment the phone disconnects — which is precisely when
    /// someone wants to look at them — so each finished session is written down as it ends.
    var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Sessions", detail: "Finished connections, newest first.")

            if model.sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.callout)
                    .foregroundStyle(HostPalette.faint)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().padding(.leading, 14) }
                        sessionRow(session)
                    }
                }
                .hostPanel()

                Text("Bytes are what the host sent: the video stream. Control traffic is a rounding error beside it.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
            }
        }
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

    // MARK: - Privacy

    /// What pairing actually grants, said plainly.
    ///
    /// Worth the space: "trusted device" is a phrase that sounds broader than it is, and the
    /// honest answer — it can see the screen you chose and send input — is both narrower and
    /// easier to reason about than a phrase like "full access".
}

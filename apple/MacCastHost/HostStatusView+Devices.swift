import AppKit
import RemoteCore
import SwiftUI

extension HostStatusView {
    /// A pin carries no name, so an unattached device is named from the last time it connected.
    var devicesSection: some View {
        // One card with a hairline between the lists: one shadow and border for the whole.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeading(String(localized: "Devices"), detail: String(localized: "Phones trusted to reach this Mac."))
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
                                detail: String(localized: "Connected · \(client.elapsedDescription())"),
                                connected: true
                            )
                        }
                        ForEach(Array(offline.enumerated()), id: \.element) { index, id in
                            if index > 0 || !connected.isEmpty { Divider().padding(.leading, 44) }
                            deviceRow(
                                name: model.displayName(for: id),
                                id: id,
                                detail: String(localized: "Trusted · not connected"),
                                connected: false
                            )
                        }
                    }
                }
            }
            .padding(16)

            Divider().padding(.leading, 16)

            remotePairingSection
                .padding(16)
        }
        .hostPanel()
    }

    /// The ID is not a secret: it is an address, and pairing still needs the six digits read out and compared, so a screenshot is no way in.
    var remotePairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                String(localized: "Pair from another network"),
                detail: String(localized: "An iPhone that is not on this network reaches this Mac by its ID. Type or scan it there, then read out the six digits when this window shows them.")
            )

            // The ID is the relay registration name and stops working when hosting stops.
            if !model.status.isListening {
                Text("Press Start first. A Mac that is not hosting is not registered with the relay, so no device can reach it by this ID.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                // Only for an ID that could be dialled: a code for an unregistered ID would send someone to the relay with a value no Mac has.
                if PairingPayload.canonicalIdentifier(model.deviceID) != nil,
                   let image = qrCode(encoding: PairingPayload.encode(hostID: model.deviceID)) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 84, height: 84)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("This Mac's device ID, as a QR code")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(model.deviceID)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Copy ID") {
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(model.deviceID, forType: .string)
                    }
                    .controlSize(.small)
                    .help("Copies the device ID on its own, for pasting into Peering on the iPhone")
                }

                Spacer(minLength: 0)
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

                // Ends the session and keeps the trust, the smaller of the two actions.
                Button {
                    model.disconnect(clientID: id)
                } label: {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hoveredDeviceID == id ? HostPalette.ink : HostPalette.muted)
                .help(String(localized: "Disconnect \(name). It stays trusted and can reconnect"))
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
            .help(String(localized: "Forget \(name). It will have to pair again"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            hoveredDeviceID == id ? HostPalette.raised : .clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .scaleEffect(hoveredDeviceID == id ? 1.004 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(HostMotion.hover) { hoveredDeviceID = hovering ? id : nil }
        }
        .help(String(localized: "Device ID \(id)"))
    }

    /// Copy all, because the lines are separate text blocks and selection drags one line at a time.
    var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading(String(localized: "Activity"), detail: String(localized: "Recent host events, newest last."))
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
                // No inner scroll view or height cap: the pane's own ScrollView scrolls and LazyVStack stays lazy inside it.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.log.enumerated()), id: \.element.id) { index, entry in
                        activityRow(entry)
                        if index < model.log.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
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
        .padding(.vertical, 12)
        .background(entry.level == .failure ? HostPalette.danger.opacity(0.055) : .clear)
    }

    /// Three tones: routine, worth noticing, did not work. A failure must be findable by skimming.
    func colour(for level: HostLogEntry.Level) -> Color {
        switch level {
        case .info: return HostPalette.faint
        case .warning: return HostPalette.caution
        case .failure: return HostPalette.danger
        }
    }

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
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "\(total)s"
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

    // MARK: - Privacy

}

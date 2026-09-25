import AppKit
import RemoteCore
import SwiftUI

/// Who is trusted, who is here, and what has happened.
extension HostStatusView {
    /// Who is trusted, and which of them is here.
    ///
    /// The absent rows matter as much as the present ones. "Is that phone still allowed in" is
    /// a question asked when the phone is *not* on the desk, and a pin — which is all the host
    /// stores for a trusted device — carries no name, so an unattached device is named from the
    /// last time it connected.
    var devicesSection: some View {
        // One card, not two. This used to be two separately shadowed, separately outlined
        // panels stacked with a gap between them — which reads as two unrelated pieces of the
        // window rather than as "who can reach this Mac", the one question both halves answer.
        // A single hairline down the middle says the same "these are different lists" the two
        // card edges used to, at a fraction of the visual weight: one shadow and one border for
        // the whole card, not one of each per half.
        VStack(alignment: .leading, spacing: 0) {
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
                }
            }
            .padding(16)

            Divider().padding(.leading, 16)

            remotePairingSection
                .padding(16)
        }
        .hostPanel()
    }

    /// This Mac's ID, and the code that carries it to an iPhone that cannot see this network.
    ///
    /// The ID is the only thing about this Mac that travels by a route other than the network,
    /// and until now it was reachable only as a tooltip and in the About pane — which is the
    /// wrong place for the one value a person has to read off this screen and type into
    /// another device. So it is shown where the pairing story is told, in the form that cannot
    /// be mistyped, and it stays there whether or not anything is paired: a Mac with one phone
    /// on it is exactly the Mac whose owner is about to pair a second.
    ///
    /// **The ID is not a secret, and this panel does not treat it as one.** It is an address,
    /// like a hostname: whoever holds it can ask the relay to reach this Mac, and what happens
    /// then is what happens across a desk — this window shows six digits, somebody here reads
    /// them out, and the phone is trusted only if the two agree. A screenshot of this panel is
    /// therefore not a way into the Mac, which is why there is no warning label on it.
    var remotePairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `sectionHeading`, not a bare `Text` — this card sits right beside the Devices one
            // and used to be the one heading in the deck set in the system face instead of the
            // display one, which read as an afterthought bolted onto the panel rather than as a
            // section with the same standing as the list above it.
            sectionHeading(
                "Pair from another network",
                detail: "An iPhone that is not on this network reaches this Mac by its ID. Type or scan it there, then read out the six digits when this window shows them."
            )

            // The ID is also the Mac's registration name at the relay, and it stops being one
            // the moment hosting stops. Said here rather than left to be discovered, because
            // the panel above it would otherwise show a perfectly good ID for a Mac that
            // nothing can reach.
            if !model.status.isListening {
                Text("Press Start first. A Mac that is not hosting is not registered with the relay, so no device can reach it by this ID.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                // Drawn only for an ID that could be dialled. Before the host has started
                // there is nothing here, and a code that scanned to an empty ID would send
                // someone to the relay with a value no Mac has ever registered.
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

                // Ends the session and keeps the trust. It is the smaller of the two hammers
                // and the one that is wanted almost every time — the other costs a pairing code
                // and a walk to the Mac.
                Button {
                    model.disconnect(clientID: id)
                } label: {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hoveredDeviceID == id ? HostPalette.ink : HostPalette.muted)
                .help("Disconnect \(name). It stays trusted and can reconnect")
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
            .help("Forget \(name). It will have to pair again")
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
                // No inner scroll view, and no height cap. This used to be boxed to 320 points
                // because it shared the pane with the device list beside it — now that Activity
                // is a pane of its own, that cap left most of a tall window as bare stage under
                // a small card. The pane's own `ScrollView` (see `HostStatusView.body`) is the
                // one that scrolls; a `LazyVStack` does not need to be that scroll view's direct
                // child to render lazily, only to be inside one.
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
            sessionSummaryValue("Sessions", "\(model.sessions.count)")
            Divider().frame(height: 34)
            sessionSummaryValue("Connected", hostDuration(model.sessions.reduce(0) { $0 + $1.duration }))
            Divider().frame(height: 34)
            sessionSummaryValue("Video", hostBytes(model.sessions.reduce(0) { $0 + Int64($1.bytes) }))
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

    /// What pairing actually grants, said plainly.
    ///
    /// Worth the space: "trusted device" is a phrase that sounds broader than it is, and the
    /// honest answer — it can see the screen you chose and send input — is both narrower and
    /// easier to reason about than a phrase like "full access".
}

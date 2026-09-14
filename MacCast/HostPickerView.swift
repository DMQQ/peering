import RemoteCore
import SwiftUI

/// Choosing a Mac, and the ways that can fail.
///
/// Bonjour is the real path, but it is not the only one and it is not always available: in the
/// simulator it frequently finds nothing at all, and on a network that blocks multicast it
/// finds nothing anywhere. The manual address field is therefore a first-class path rather
/// than a debug affordance — the brief is explicit that a client whose only route in is a
/// discovery protocol it does not control has no route in.
struct HostPickerView: View {
    @Environment(SessionModel.self) private var model
    @State private var showsManualConnection = false

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ZStack {
                ColorPalette.backdrop.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero

                        if let failure = model.identityFailure {
                            identitySection(failure)
                        }

                        nearbyCard
                        manualCard(address: $model.manualAddress, port: $model.manualPort)
                        pairedCard

                        Text(model.thisDeviceDescription)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .accessibilityLabel("Diagnostics")
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(ColorPalette.ink)
                Text("Peering")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Text("LOCAL · PRIVATE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }

            DeviceLinkArtwork()
                .frame(height: 176)

            Text("Your Mac, right here.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-1)

            Text("See the screen, switch apps, and control the pointer over your local network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Nearby", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button { model.restartBrowsing() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search again")
            }

            if model.hosts.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(ColorPalette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looking for Macs")
                            .font(.subheadline.weight(.semibold))
                        Text(model.browseStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } else {
                ForEach(model.hosts) { host in
                    Button { model.connect(to: .discovered(host)) } label: { hostRow(host) }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy || !isCompatible(host))
                }
                Text(model.browseStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func manualCard(address: Binding<String>, port: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showsManualConnection) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("Mac address", text: address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        TextField("Port", text: port)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .frame(width: 88)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button { model.connectToManualAddress() } label: {
                        Label("Connect", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ColorPalette.ink)
                    .foregroundStyle(.black)
                    .disabled(model.isBusy || model.manualAddress.isEmpty)
                }
                .padding(.top, 12)
            } label: {
                Label("Connect by address", systemImage: "network")
                    .font(.headline)
            }
        }
        .cardSurface()
    }

    private var pairedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Trusted Macs", systemImage: "checkmark.shield")
                .font(.headline)
            if model.pairedHostIDs.isEmpty {
                Text("A Mac appears here after your first secure pairing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.pairedHostIDs, id: \.self) { hostID in
                    HStack {
                        Text(hostID)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Forget", role: .destructive) { model.forget(hostID: hostID) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Rows

    private func hostRow(_ host: DiscoveredHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "macbook")
                .font(.title3)
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 42, height: 42)
                .background(ColorPalette.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                HStack(spacing: 6) {
                    Text(host.id.prefix(8))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if host.interfaceCount > 1 {
                        Text("· \(host.interfaceCount) interfaces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let version = host.protocolVersion, version != ProtocolInfo.version {
                // Shown rather than hidden, and the row is disabled: connecting would fail
                // after a TLS handshake, which is a slow way to learn something the TXT
                // record already said.
                // A filled chip rather than a coloured one: this is the only row on the screen
                // that cannot be tapped, so it has to look different rather than merely say
                // something different.
                Text("v\(version)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ColorPalette.selectedFill, in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private func identitySection(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This device has no identity", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ColorPalette.ink)
            Text(failure)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset identity") { model.resetDeviceIdentity() }
        }
        .cardSurface()
    }

    /// Whether the advertised protocol version is one this app can speak.
    ///
    /// An absent version is treated as compatible: older hosts publish only the device ID, and
    /// refusing them would hide a Mac that works perfectly well.
    private func isCompatible(_ host: DiscoveredHost) -> Bool {
        guard let version = host.protocolVersion else { return true }
        return version == ProtocolInfo.version
    }
}

private struct DeviceLinkArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.035))

            HStack(spacing: 34) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.1))
                        .frame(width: 150, height: 96)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(ColorPalette.surface)
                                .padding(5)
                                .overlay {
                                    Image(systemName: "cursorarrow.motionlines")
                                        .font(.system(size: 27, weight: .medium))
                                        .foregroundStyle(ColorPalette.ink)
                                }
                        }
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .frame(width: 174, height: 7)
                        .offset(y: 7)
                }

                HStack(spacing: 5) {
                    Circle().fill(ColorPalette.ink.opacity(0.35)).frame(width: 5, height: 5)
                    Circle().fill(ColorPalette.ink.opacity(0.65)).frame(width: 6, height: 6)
                    Circle().fill(ColorPalette.ink).frame(width: 7, height: 7)
                }

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.white.opacity(0.11))
                    .frame(width: 58, height: 112)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(ColorPalette.ink.opacity(0.55), lineWidth: 1.5)
                            .padding(4)
                    }
            }
            .offset(x: -4, y: -3)
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    func cardSurface() -> some View {
        self
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.1))
            }
    }
}

/// Everything that is useful when something has gone wrong and noise otherwise.
struct DiagnosticsView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Mac", value: model.hostName ?? "—")
                LabeledContent("State", value: state)
                LabeledContent("Display", value: model.videoStatus)
                if let tls = model.tlsDescription {
                    LabeledContent("Transport", value: tls)
                }
                if let latency = model.latencyMilliseconds {
                    LabeledContent("Control latency", value: "\(Int(latency.rounded())) ms")
                }
                LabeledContent("Source", value: model.activeSourceID ?? "—")
            }

            Section("This device") {
                Text(model.thisDeviceDescription)
                    .font(.footnote.monospaced())
            }

            Section("Log") {
                if model.notes.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var state: String {
        switch model.phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .handshaking: return "Handshaking"
        case .confirming: return "Confirming the pairing code"
        case .ready: return "Connected"
        case .failed(let message): return "Failed — \(message)"
        case .disconnected: return "Disconnected"
        }
    }
}

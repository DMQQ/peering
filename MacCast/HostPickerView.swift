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

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            List {
                if let failure = model.identityFailure {
                    identitySection(failure)
                }

                Section {
                    if model.hosts.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.hosts) { host in
                            Button {
                                model.connect(to: .discovered(host))
                            } label: {
                                hostRow(host)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isBusy || !isCompatible(host))
                        }
                    }
                } header: {
                    HStack {
                        Text("Macs on this network")
                        Spacer()
                        Button {
                            model.restartBrowsing()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search again")
                    }
                } footer: {
                    Text(model.browseStatus)
                }

                Section {
                    TextField("Address", text: $model.manualAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $model.manualPort)
                        .keyboardType(.numberPad)
                    Button {
                        model.connectToManualAddress()
                    } label: {
                        Label("Connect", systemImage: "arrow.right.circle")
                    }
                    .disabled(model.isBusy || model.manualAddress.isEmpty)
                } header: {
                    Text("Connect by address")
                } footer: {
                    Text("Defaults to this Mac's loopback address, which is what the simulator needs — Bonjour does not work reliably there.")
                }

                Section("Paired Macs") {
                    if model.pairedHostIDs.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pairedHostIDs, id: \.self) { hostID in
                            HStack {
                                Text(hostID)
                                    .font(.footnote.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) {
                                    model.forget(hostID: hostID)
                                } label: {
                                    Text("Forget")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("This device") {
                    LabeledContent("Identity", value: model.thisDeviceDescription)
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }
            }
            .navigationTitle("MacCast")
        }
    }

    // MARK: - Rows

    private func hostRow(_ host: DiscoveredHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

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
                Text("v\(version)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.25))
                    .clipShape(Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func identitySection(_ failure: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("This device has no identity", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset identity") { model.resetDeviceIdentity() }
            }
        }
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

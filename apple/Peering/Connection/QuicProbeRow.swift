#if DEBUG
import Network
import RemoteCore
import SwiftUI

/// The QUIC spike's button: runs ``QuicProbe`` against a Mac's echo server and shows what it measured. Debug builds only.
struct QuicProbeRow: View {
    let model: SessionModel
    @State private var address = ""
    @State private var lines: [String] = []
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Controls.row(String(localized: "QUIC test"), systemImage: "bolt.horizontal") {
                Button(isRunning ? String(localized: "Running…") : String(localized: "Run")) { run() }
                    .disabled(isRunning || address.isEmpty || model.identity == nil)
                    .font(.subheadline.weight(.semibold))
            }
            TextField(String(localized: "Mac address"), text: $address)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear { if address.isEmpty { address = Self.rememberedAddress(in: model) ?? "" } }
    }

    private func run() {
        guard let identity = model.identity else { return }
        isRunning = true
        lines = []
        let host = address.trimmingCharacters(in: .whitespaces)
        Task {
            let report = await QuicProbe.run(host: host, port: QuicEchoServer.port, identity: identity)
            lines = report.lines
            isRunning = false
        }
    }

    /// The last LAN address a Mac was reached at, when it was a plain IP.
    private static func rememberedAddress(in model: SessionModel) -> String? {
        for host in model.lastLANHosts.values {
            guard case .hostPort(let address, _) = host.endpoint else { continue }
            switch address {
            case .ipv4(let v4): return "\(v4)"
            case .ipv6(let v6): return "\(v6)"
            default: continue
            }
        }
        return nil
    }
}
#endif

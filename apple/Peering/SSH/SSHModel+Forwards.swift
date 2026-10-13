import Foundation
import PeeringKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    func forwardState(_ forward: SSHPortForward, on host: SSHHost) -> SSHForwardState {
        forwardStates[host.id]?[forward.id] ?? .stopped
    }

    func hasRunningForward(on host: SSHHost) -> Bool {
        (forwardStates[host.id]?.values.contains { $0.isRunning }) ?? false
    }

    func hasBrokenForward(on host: SSHHost) -> Bool {
        (forwardStates[host.id]?.values.contains { state in
            if case .failed = state { return true }
            return false
        }) ?? false
    }

    /// The dialer resolves the session when called, so one forwarder outlives the shell that started it: a second shell picks up the same listening sockets. Holding the session directly would pin the first shell open as long as its forwards run.
    private func forwarder(for host: SSHHost) -> SSHForwarder {
        if let existing = forwarders[host.id] { return existing }

        let id = host.id
        let forwarder = SSHForwarder { [weak self] remoteHost, remotePort, localPort in
            guard let session = await self?.currentSession(for: id) else {
                throw SSHSessionError.notConnected
            }
            return try await session.openDirectChannel(to: remoteHost, port: remotePort, from: localPort)
        }

        forwarders[host.id] = forwarder
        // States are pushed, not polled: a server-side refusal happens whenever another app takes the port, never at a moment this screen caused.
        Task { @MainActor [weak self] in
            for await states in forwarder.changes {
                self?.forwardStates[id] = states
            }
        }
        return forwarder
    }

    @MainActor
    private func currentSession(for hostID: UUID) -> SSHSession? {
        hostSessions[hostID]?.first { session in
            terminals.contains { $0.session === session && isLive($0) }
        }
    }

    /// Automatic, as in OpenSSH's config: writing the forward down on the server is the intent. Not silent: a failed forward lands in `forwardStates` and the toolbar button says so.
    func startEnabledForwards(on host: SSHHost) async {
        let forwarder = forwarder(for: host)
        for forward in host.forwards where forward.isEnabled {
            // A forward already listening is left alone: this runs per shell that opens, and a second shell must not rebuild the first's tunnels.
            guard await forwarder.state(of: forward.id) == .stopped else { continue }
            try? await forwarder.start(forward)
        }
    }

    func start(_ forward: SSHPortForward, on host: SSHHost) async {
        // The throw is dropped: a failed bind is already in the forward's own state with the same sentence.
        try? await forwarder(for: host).start(forward)
    }

    func stop(_ forward: SSHPortForward, on host: SSHHost) async {
        await forwarder(for: host).stop(forward.id)
    }

    func stopForwards(on hostID: UUID) async {
        await forwarders[hostID]?.stopAll()
    }
}

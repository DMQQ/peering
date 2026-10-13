import Foundation
import PeeringKit
import Observation
import RemoteCore
import os

private let controllerLog = Logger(subsystem: "pl.dmq.peering.host", category: "terminal-hooks")

/// Whether Peering is hooked into Claude Code, and the socket that listens while it is.
@MainActor
@Observable
final class TerminalHookController {
    private(set) var isInstalled = TerminalHookInstaller.isInstalled()
    private(set) var failure: String?

    @ObservationIgnored private var broker: ClaudeHookBroker?
    @ObservationIgnored private var server: TerminalHookServer?

    /// The broker answers a phone's tap: the host's agent code asks it first, since a hook has no chat to belong to.
    var resolver: (@Sendable (String, AgentApprovalDecision) -> Bool)? {
        guard let broker else { return nil }
        return { broker.resolve(approvalID: $0, decision: $1) }
    }

    func attach(tokens: @escaping @Sendable () -> [String], push: @escaping ClaudeHookBroker.Push) {
        broker = ClaudeHookBroker(tokens: tokens, push: push, words: .localized)
        listenIfInstalled()
    }

    func detach() {
        server?.stop()
        server = nil
        broker = nil
    }

    func install() { change { try TerminalHookInstaller.install() } }

    func uninstall() { change { try TerminalHookInstaller.uninstall() } }

    private func change(_ work: () throws -> Void) {
        do {
            try work()
            failure = nil
        } catch {
            HostTelemetry.hookInstallFailed(error)
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            controllerLog.error("hook settings change failed: \(error.localizedDescription, privacy: .public)")
        }
        isInstalled = TerminalHookInstaller.isInstalled()
        listenIfInstalled()
    }

    private func listenIfInstalled() {
        guard let broker else { return }
        guard isInstalled else {
            server?.stop()
            server = nil
            return
        }
        guard server == nil else { return }
        let server = TerminalHookServer { event, reply in broker.handle(event, reply: reply) }
        do {
            try server.start()
            self.server = server
        } catch {
            failure = String(localized: "Peering could not listen for Claude Code: \(error.localizedDescription)")
            controllerLog.error("hook socket failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

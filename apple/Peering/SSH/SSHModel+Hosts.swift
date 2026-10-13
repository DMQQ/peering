import Foundation
import PeeringKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    /// The list lives in ``QuickCommands``.
    /// Sent as the command then a carriage return, as typing would be: a shell has no "execute" path, and its history keeps it.
    func run(_ command: SSHQuickCommand, on terminal: SSHTerminal) {
        send(Data(command.command.utf8), to: terminal)
        send(Data("\r".utf8), to: terminal)
    }

    func save(_ host: SSHHost) {
        Analytics.featureUsed(.sshHostSaved)
        saved.removeAll { $0.id == host.id }
        saved.append(host)
        store.save(saved)
        hosts = SSHHostStore.ordered(saved)
        mirrorServers()

        // A server that no longer asks for a passcode must not keep one: it would wait for the next passcode the user sets here.
        if host.lock != .passcode, passcodes.hasPasscode(for: host.id) {
            passcodes.remove(for: host.id)
        }
    }

    func delete(_ host: SSHHost) {
        Analytics.featureUsed(.sshHostDeleted)
        saved.removeAll { $0.id == host.id }
        store.save(saved)
        hosts = SSHHostStore.ordered(saved)
        mirrorServers()
        // The credential, pinned key and passcode go with it: otherwise a re-added host silently reuses a deleted password, and a passcode lock opens for a number nobody set on this server.
        credentials.remove(for: host.id)
        passcodes.remove(for: host.id)
    }

    /// Asks about a credential, not a password: a host that logs in with a key must not be sent to a password sheet.
    func hasStoredCredential(for host: SSHHost) -> Bool {
        credentials.hasCredential(for: host.id)
    }

    /// Returns the whole credential, not a password: unwrapping to a string would put the enum back in every caller's hands.
    func storedCredential(for host: SSHHost) -> SSHCredential? {
        credentials.credential(for: host.id)
    }

    func credentialKind(for host: SSHHost) -> String? {
        switch storedCredential(for: host) {
        case .password: return String(localized: "Password saved")
        case .key: return String(localized: "Key saved")
        case nil: return nil
        }
    }

    func store(password: String, for host: SSHHost, remember: Bool) {
        guard remember else { return }
        credentials.save(.password(password), for: host.id)
    }

    /// `.unchanged` must not write: a keychain write on every edit can land on top of a key something else changed. This is the only place that acts on ``SSHSecretChange``.
    func apply(_ change: SSHSecretChange, to host: SSHHost, rememberPassword: Bool) {
        switch change {
        case .unchanged:
            break
        case .use(.password(let password)):
            store(password: password, for: host, remember: rememberPassword)
        case .use(.key(let key)):
            store(key: key, for: host)
        case .forget:
            forgetCredential(for: host)
        }
    }

    /// Replacing, not coexisting, is why ``SSHCredential`` is an enum: a host given a key must not still hold its password.
    @discardableResult
    func store(key: SSHKeyPair, for host: SSHHost) -> Bool {
        credentials.save(.key(key), for: host.id)
    }

    @discardableResult
    func forgetCredential(for host: SSHHost) -> Bool {
        credentials.remove(for: host.id)
    }

    /// Forgets a pinned key so the next connection asks as a first sight; the only route past a changed key (``SSHSessionError/hostKeyChanged(known:presented:)``).
    func forgetKey(for host: SSHHost) {
        knownHosts.forget(host.endpoint)
    }

    func isKeyKnown(for host: SSHHost) -> Bool {
        knownHosts.host(for: host.endpoint) != nil
    }
}

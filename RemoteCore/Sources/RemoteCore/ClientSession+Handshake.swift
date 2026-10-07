import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    func handle(_ frame: Frame) {
        lock.lock()
        let current = state
        lock.unlock()

        switch current {
        case .awaitingServerHello: handleServerHello(frame)
        case .awaitingServerCommit: handleServerCommit(frame)
        case .awaitingServerReveal: handleServerReveal(frame)
        case .awaitingUserConfirmation:
            // Nothing is expected here: a frame now would mean the Mac raced ahead of a decision
            // the user has not made yet, so it is ignored rather than acted on.
            clientSessionLog.notice("ignoring \(String(describing: frame.kind), privacy: .public) while awaiting the user's pairing decision")
        case .awaitingPairResult: handlePairResult(frame)
        case .ready: handleReady(frame)
        case .idle, .failed:
            break
        }
    }

    func handleServerHello(_ frame: Frame) {
        guard frame.kind == .serverHello else {
            fail(Failure.unexpected(frame.kind, expected: "serverHello").errorDescription ?? "")
            return
        }
        guard let hello = try? MessageCodec.decode(ServerHello.self, from: frame.payload) else {
            fail("The Mac's hello could not be read.")
            return
        }
        guard hello.protocolVersion == ProtocolInfo.version else {
            fail(Failure.protocolMismatch(client: ProtocolInfo.version, host: hello.protocolVersion).errorDescription ?? "")
            return
        }
        guard let serverKey = lock.withLock({ _serverKey }) else {
            fail(Failure.noServerKey.errorDescription ?? "")
            return
        }

        // Before the pin and before the pairing: is this the Mac that was dialled? Checked here
        // rather than at the relay, which routes by ID but answers for whatever holds it.
        if let dialled = lock.withLock({ pairingHostID }), hello.serverID != dialled {
            fail(Failure.hostIDMismatch(dialled: dialled, answered: hello.serverID).errorDescription ?? "")
            return
        }

        lock.withLock { _serverHello = hello }
        emit(.host(hello))

        // The pin is checked after the handshake because until `serverHello` there is no knowing which Mac this is. Nothing an impostor could use has been sent yet.
        if let stored = pins.pin(for: hello.serverID) {
            guard SPKI.matches(stored, serverKey) else {
                fail(Failure.pinMismatch(hostID: hello.serverID).errorDescription ?? "")
                return
            }
            emit(.note("The Mac's key matches the pin stored for it."))
        } else if hello.alreadyPaired {
            // Reached only when this device lost its pin store while the Mac kept its half. Not a
            // way in for an attacker: the Mac only answers `alreadyPaired` to a client whose
            // certificate it recognises, and our identity key is `…ThisDeviceOnly`, so a backup
            // restore cannot carry it here. Re-pin with the server key already verified over TLS.
            if pins.record(hostID: hello.serverID, publicKey: serverKey) {
                emit(.note("The Mac already knows this device. Pin restored. It will appear in Trusted Macs again."))
            } else {
                emit(.note("The Mac already knows this device, but the pin could not be saved. Keychain may be unavailable."))
            }
        }

        if hello.alreadyPaired {
            becomeReady()
        } else {
            beginPairing()
        }
    }

    /// Opens the commitment exchange. See ``PairingSAS`` for why the commitment exists:
    /// without it an active attacker grinds a keypair until its own contribution reproduces
    /// the digits the Mac is about to display.
    func beginPairing() {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        guard let nonce = try? Self.randomBytes(32) else {
            fail("This device could not obtain secure random bytes.")
            return
        }
        lock.withLock {
            self.ephemeral = ephemeral
            self.nonce = nonce
            state = .awaitingServerCommit
        }

        let commitment = PairingSAS.commitment(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        )
        connection()?.send(.pairCommit, PairingCommit(commitment: commitment))
    }

    func handleServerCommit(_ frame: Frame) {
        guard frame.kind == .pairCommit else {
            fail(Failure.unexpected(frame.kind, expected: "pairCommit").errorDescription ?? "")
            return
        }
        guard let commit = try? MessageCodec.decode(PairingCommit.self, from: frame.payload),
              let ephemeral = lock.withLock({ self.ephemeral }),
              let nonce = lock.withLock({ self.nonce })
        else {
            fail("The Mac's pairing commitment could not be read.")
            return
        }

        lock.withLock {
            remoteCommitment = commit.commitment
            state = .awaitingServerReveal
        }

        // Reveal only now, having seen the Mac's commitment. Sending ours first would let it
        // pick its own contribution with ours already known.
        connection()?.send(.pairReveal, PairingReveal(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        ))
    }

    func handleServerReveal(_ frame: Frame) {
        guard frame.kind == .pairReveal else {
            fail(Failure.unexpected(frame.kind, expected: "pairReveal").errorDescription ?? "")
            return
        }
        guard let reveal = try? MessageCodec.decode(PairingReveal.self, from: frame.payload) else {
            fail("The Mac's pairing reveal could not be read.")
            return
        }

        // Read as separate locals rather than one destructured tuple: a five-element tuple of
        // optionals is the kind of expression the type checker gives up on.
        lock.lock()
        let ephemeral = self.ephemeral
        let nonce = self.nonce
        let commitment = self.remoteCommitment
        let hello = self._serverHello
        let serverKey = self._serverKey
        lock.unlock()

        guard let ephemeral, let nonce, let commitment, let hello, let serverKey else {
            fail("The pairing exchange lost its state.")
            return
        }

        guard PairingSAS.verify(
            commitment: commitment,
            ephemeralPublicKey: reveal.ephemeralPublicKey,
            nonce: reveal.nonce
        ) else {
            fail(Failure.commitmentMismatch.errorDescription ?? "")
            return
        }

        // The transcript binds everything both sides exchanged, in a fixed order, with the Mac's
        // identity key taken from the certificate we actually received rather than from an
        // application-layer field, which a man in the middle would simply rewrite.
        let transcript = PairingTranscript(
            protocolVersion: ProtocolInfo.version,
            clientID: clientID,
            serverID: hello.serverID,
            clientEphemeralPublicKey: ephemeral.publicKey.x963Representation,
            serverEphemeralPublicKey: reveal.ephemeralPublicKey,
            clientNonce: nonce,
            serverNonce: reveal.nonce,
            serverIdentityPublicKey: serverKey
        )

        let code = PairingSAS.code(for: transcript)
        lock.withLock {
            state = .awaitingUserConfirmation
            _phase = .confirming(code: code)
        }
        emit(.phase(.confirming(code: code)))
    }

    func handlePairResult(_ frame: Frame) {
        guard frame.kind == .pairResult else {
            fail(Failure.unexpected(frame.kind, expected: "pairResult").errorDescription ?? "")
            return
        }
        guard let result = try? MessageCodec.decode(PairResult.self, from: frame.payload) else {
            fail("The Mac's pairing result could not be read.")
            return
        }
        guard result.accepted else {
            fail(result.reason ?? "The Mac refused the pairing.")
            return
        }

        // Recorded only once the Mac has confirmed it stored its half: a pin the Mac never agreed
        // to would leave every later connection failing with a mismatch that looks like an attack.
        lock.lock()
        let hello = self._serverHello
        let serverKey = self._serverKey
        lock.unlock()

        if let hello, let serverKey, !pins.record(hostID: hello.serverID, publicKey: serverKey) {
            fail("The pairing succeeded but this device could not save it. Check that the Keychain is available.")
            return
        }

        emit(.note("Paired and pinned."))
        becomeReady()
    }
}

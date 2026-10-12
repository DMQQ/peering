import CryptoKit
import Foundation
import MacCastKit
import RemoteCore
import os

extension HostSession {
    /// Starts the commitment exchange. The commitment exists because without it an active attacker
    /// can grind a keypair until its own contribution reproduces the digits this host is about to
    /// put on screen. See ``PairingSAS``.
    func beginPairing() throws {
        if let refusal = claimPairingPrompt?() {
            refusePairing(refusal)
            return
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let nonce = try Self.randomBytes(32)

        localEphemeral = ephemeral
        localNonce = nonce

        let commitment = PairingSAS.commitment(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        )
        send(.pairCommit, PairingCommit(commitment: commitment))
        state = .awaitingClientCommit
    }

    func handleClientCommit(_ frame: Frame) throws {
        guard frame.kind == .pairCommit else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.pairCommit, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let commit = try decode(PairingCommit.self, from: frame, as: .pairCommit)
        remoteCommitment = commit.commitment

        // Only now, having committed to our own value, do we reveal it.
        guard let ephemeral = localEphemeral, let nonce = localNonce else {
            throw SessionError.unexpectedMessage(frame.kind)
        }
        send(.pairReveal, PairingReveal(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        ))
        state = .awaitingClientReveal
    }

    func handleClientReveal(_ frame: Frame) throws {
        guard frame.kind == .pairReveal else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.pairReveal, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let reveal = try decode(PairingReveal.self, from: frame, as: .pairReveal)

        guard let commitment = remoteCommitment,
              PairingSAS.verify(
                  commitment: commitment,
                  ephemeralPublicKey: reveal.ephemeralPublicKey,
                  nonce: reveal.nonce
              )
        else {
            throw SessionError.commitmentMismatch
        }

        remoteEphemeralPublicKey = reveal.ephemeralPublicKey
        remoteNonce = reveal.nonce

        let transcript = PairingTranscript(
            protocolVersion: ProtocolInfo.version,
            clientID: clientID,
            serverID: device.id,
            clientEphemeralPublicKey: reveal.ephemeralPublicKey,
            serverEphemeralPublicKey: localEphemeral?.publicKey.x963Representation ?? Data(),
            clientNonce: reveal.nonce,
            serverNonce: localNonce ?? Data(),
            serverIdentityPublicKey: identity.publicKeyBytes
        )

        pairingTranscript = transcript
        pairingSecret = try Self.randomBytes(16)
        emit(.pairingCode(
            sessionID: id,
            code: PairingSAS.code(for: transcript),
            secret: pairingSecret,
            clientName: clientName,
            isRemote: arrivedThroughRelay
        ))
        state = .awaitingConfirmation
    }

    func handlePairConfirm(_ frame: Frame) throws {
        guard frame.kind == .pairConfirm else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.pairConfirm, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let confirm = try decode(PairConfirm.self, from: frame, as: .pairConfirm)

        guard confirm.accepted, let peerPublicKey else {
            HostTelemetry.pairingRefused(stage: .confirm)
            rejectPairing(reason: "The codes did not match.")
            return
        }

        if let proof = confirm.proof {
            guard let transcript = pairingTranscript,
                  PairingSAS.verifyProof(proof, secret: pairingSecret, transcript: transcript)
            else {
                HostTelemetry.pairingRefused(stage: .proof)
                rejectPairing(reason: "The pairing code was not accepted.")
                return
            }
            finishPairing(peerPublicKey: peerPublicKey)
        } else {
            // Digits typed by hand prove nothing: they can be computed from the handshake by anyone.
            state = .awaitingApproval
            emit(.pairingNeedsApproval(sessionID: id, clientName: clientName))
        }
    }

    /// The Mac user's answer for a pairing that arrived without the QR secret.
    func resolveApproval(approved: Bool) {
        guard state == .awaitingApproval, let peerPublicKey, approved else {
            if state == .awaitingApproval { HostTelemetry.pairingRefused(stage: .approval); rejectPairing(reason: "The pairing was declined on the Mac.") }
            return
        }
        finishPairing(peerPublicKey: peerPublicKey)
    }

    /// Ends a pairing this Mac's user did not get to see: the prompt is taken, or too many have been asked for.
    private func refusePairing(_ refusal: PairingGate.Refusal) {
        let reason: String
        switch refusal {
        case .anotherPairingInProgress: reason = "Another device is pairing with this Mac right now. Try again in a minute."
        case .tooManyAttempts: reason = "Too many pairing attempts. Try again in a minute."
        }
        hostSessionLog.notice("refused a pairing attempt: \(String(describing: refusal), privacy: .public)")
        send(.pairResult, PairResult(accepted: false, reason: reason))
        state = .failed
        connection.cancel()
    }

    private func rejectPairing(reason: String) {
        send(.pairResult, PairResult(accepted: false, reason: reason))
        _ = releasePairingPrompt?()
        emit(.pairingCompleted(sessionID: id, clientName: clientName, accepted: false))
        state = .failed
        connection.cancel()
    }

    private func finishPairing(peerPublicKey: Data) {
        guard pins.record(peerID: clientID, publicKey: peerPublicKey) else {
            // Reporting success would tell the user they are paired while the next connection
            // silently fails, so the write result is checked rather than assumed.
            HostTelemetry.pairingRefused(stage: .save)
            rejectPairing(reason: "Could not save the pairing.")
            return
        }

        send(.pairResult, PairResult(accepted: true))
        _ = releasePairingPrompt?()
        emit(.pairingCompleted(sessionID: id, clientName: clientName, accepted: true))
        becomeReady()
    }

    /// Lifts the small frame cap that applies until the peer is known, then tells the server.
    func becomeReady() {
        connection.limitFrames(to: nil)
        state = .ready
        onAuthorized?(connection)
    }
}

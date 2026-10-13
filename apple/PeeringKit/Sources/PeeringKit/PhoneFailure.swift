import Foundation
import RemoteCore

/// The properties of the iPhone app's failure events: a stage and a reason from closed sets plus the numeric code, and nothing an error sentence, a name, an address or a path could ride in on.
public enum PhoneFailure {
    public enum Event: String, Sendable, CaseIterable {
        case pairing = "pairing_failed"
        case fileTransfer = "file_transfer_failed"
        case terminal = "terminal_failed"
        case ssh = "ssh_failed"
        case agent = "agent_failed"
        case pushRegistration = "push_registration_failed"
        case purchase = "purchase_failed"
        case receiptVerification = "receipt_verification_failed"
        case pinStoreUnreadable = "pin_store_unreadable"
    }

    public enum PairingStage: String, Sendable, CaseIterable {
        case codeEntry, qr, commit, confirm, pinStore
    }

    /// Why a pairing did not complete, from a closed set. Only `session` carries a name from outside this file, and that one is itself a closed enum.
    public enum PairingReason: Equatable, Sendable {
        case empty, pairingCodeNotAnID, notAPairingCode, notAnID, codeMismatch, cancelled
        case session(ClientSession.FailureReason)

        public var name: String {
            switch self {
            case .empty: "empty"
            case .pairingCodeNotAnID: "pairingCodeNotAnID"
            case .notAPairingCode: "notAPairingCode"
            case .notAnID: "notAnID"
            case .codeMismatch: "codeMismatch"
            case .cancelled: "cancelled"
            case .session(let reason): reason.rawValue
            }
        }
    }

    public enum TransferDirection: String, Sendable {
        case up, down
    }

    public enum TransferStage: String, Sendable {
        case measure, read, send, write
    }

    public enum SSHStage: String, Sendable, CaseIterable {
        case dns, connect, handshake, hostKey, auth, channel, sftp
    }

    public enum TerminalStage: String, Sendable {
        case start, stream
    }

    public enum AgentStage: String, Sendable, CaseIterable {
        case start, stream, approval, commit, push

        public init(operation: AgentGitOperation) {
            switch operation {
            case .commit: self = .commit
            case .push: self = .push
            }
        }
    }

    /// Why an answer to an agent's approval did not reach the Mac: no usable connection, or no confirmation in time.
    public static func approvalCause(wasSent: Bool) -> Cause {
        wasSent ? .timedOut : .offline
    }

    public static func agentProperties(stage: AgentStage, cause: Cause) -> [String: any Sendable] {
        properties(stage: stage, reason: cause.rawValue, code: nil)
    }

    /// What an error says about itself without its message: the broad kind, from the error's domain and code.
    public enum Cause: String, Sendable, CaseIterable {
        case cancelled, timedOut, offline, dnsFailed, refused, unreachable, hostClosed, tls
        case denied, notFound, diskFull, unreadable, hostReported, other
    }

    public static func properties(reason: String, code: Int?, extra: [String: any Sendable] = [:]) -> [String: any Sendable] {
        properties(stage: Optional<PairingStage>.none, reason: reason, code: code, extra: extra)
    }

    public static func properties<Stage: RawRepresentable<String>>(stage: Stage?, reason: String, code: Int?, extra: [String: any Sendable] = [:]) -> [String: any Sendable] {
        var properties = extra
        properties["reason"] = reason
        if let stage { properties["stage"] = stage.rawValue }
        if let code { properties["error_code"] = code }
        return properties
    }

    /// `code` is the POSIX or URL error number, the only part of a system error worth keeping.
    public static func cause(of error: Error) -> (cause: Cause, code: Int?) {
        if error is CancellationError { return (.cancelled, nil) }
        let nsError = error as NSError
        let code = nsError.code
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            switch Int32(truncatingIfNeeded: code) {
            case ECANCELED: return (.cancelled, code)
            case ETIMEDOUT: return (.timedOut, code)
            case ECONNREFUSED: return (.refused, code)
            case ENETDOWN, ENETUNREACH, EHOSTUNREACH, EHOSTDOWN: return (.unreachable, code)
            case ECONNRESET, EPIPE, ECONNABORTED, ENOTCONN: return (.hostClosed, code)
            case EACCES, EPERM: return (.denied, code)
            case ENOENT: return (.notFound, code)
            case ENOSPC, EDQUOT: return (.diskFull, code)
            default: return (.other, code)
            }
        case NSURLErrorDomain:
            switch code {
            case NSURLErrorCancelled: return (.cancelled, code)
            case NSURLErrorTimedOut: return (.timedOut, code)
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return (.offline, code)
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return (.dnsFailed, code)
            case NSURLErrorCannotConnectToHost: return (.refused, code)
            case NSURLErrorNetworkConnectionLost: return (.hostClosed, code)
            default: return (.other, code)
            }
        case NSCocoaErrorDomain:
            switch code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return (.notFound, code)
            case NSFileWriteOutOfSpaceError: return (.diskFull, code)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return (.denied, code)
            case NSFileReadCorruptFileError: return (.unreadable, code)
            default: return (.other, code)
            }
        default:
            return (.other, code)
        }
    }

    /// The name of an enum error's case, kept only when it is one of `allowed`, so a payload (a path, a name) can never reach an event.
    public static func caseName(of error: Error, allowed: Set<String>) -> String {
        guard Mirror(reflecting: error).displayStyle == .enum else { return "other" }
        let name = String(String(describing: error).prefix { $0 != "(" })
        return allowed.contains(name) ? name : "other"
    }

    // MARK: Pairing

    public static func pairingReason(_ problem: PairingPayloadError) -> PairingReason {
        switch problem {
        case .empty: .empty
        case .shortAuthenticationCode: .pairingCodeNotAnID
        case .unrecognisedCode: .notAPairingCode
        case .notAnIdentifier: .notAnID
        }
    }

    /// The stage a refused pairing got to, from the reason and the connect stage the session had reached. A commitment that does not match the Mac's reveal reads as `handshake` at the pairing stage, and so as `commit`.
    public static func pairingFailure(reason: ClientSession.FailureReason, stage: ConnectStage) -> (stage: PairingStage, reason: PairingReason)? {
        switch reason {
        case .pairingRefused: return (.confirm, .session(reason))
        case .pairingNotSaved: return (.pinStore, .session(reason))
        case .handshake where stage == .pairing: return (.commit, .codeMismatch)
        default:
            guard stage == .pairing else { return nil }
            return (.commit, .session(reason))
        }
    }

    // MARK: Files

    public static func transferProperties(direction: TransferDirection, stage: TransferStage, error: Error, bytes: Int64?) -> [String: any Sendable] {
        let found = cause(of: error)
        return properties(
            stage: stage, reason: found.cause.rawValue, code: found.code,
            extra: ["direction": direction.rawValue, "size_bucket": bytes.map(ConnectionBuckets.bytes) ?? "unknown"]
        )
    }

    // MARK: SSH

    private static let sshCases: Set<String> = ["hostKeyRejected", "hostKeyChanged", "transport", "notConnected", "browse", "forward"]

    /// The stage and reason of an SSH failure from the error's case name and, for a transport error, its cause. A forward failure is its own reason, since the shell stays usable.
    public static func sshFailure(_ error: Error, after connected: Bool) -> (stage: SSHStage, reason: String, code: Int?) {
        let name = caseName(of: error, allowed: sshCases)
        let found = cause(of: error)
        switch name {
        case "hostKeyRejected": return (.hostKey, "rejected", nil)
        case "hostKeyChanged": return (.hostKey, "changed", nil)
        case "browse": return (.sftp, found.cause.rawValue, found.code)
        case "forward": return (.channel, "forwardFailed", found.code)
        default:
            let typeName = String(describing: type(of: error)).lowercased()
            if typeName.contains("auth") { return (.auth, "rejected", found.code) }
            if found.cause == .dnsFailed { return (.dns, found.cause.rawValue, found.code) }
            if connected { return (.channel, found.cause.rawValue, found.code) }
            return (found.cause == .other ? .handshake : .connect, found.cause.rawValue, found.code)
        }
    }

    // MARK: Store and push

    private static let purchaseCases: Set<String> = [
        "networkError", "systemError", "notAvailableInStorefront", "notEntitled", "unknown",
        "invalidQuantity", "invalidOfferIdentifier", "invalidOfferPrice", "invalidOfferSignature", "missingOfferParameters",
        "productUnavailable", "purchaseNotAllowed", "ineligibleForOffer",
    ]

    public static func purchaseReason(_ error: Error) -> String {
        let name = caseName(of: error, allowed: purchaseCases)
        return name == "other" ? cause(of: error).cause.rawValue : name
    }

    private static let verificationCases: Set<String> = [
        "revokedCertificate", "invalidCertificateChain", "invalidDeviceVerification", "invalidEncoding", "invalidSignature", "missingRequiredProperties",
    ]

    public static func receiptReason(_ error: Error) -> String {
        caseName(of: error, allowed: verificationCases)
    }

    /// 3000 is a build with no push entitlement and 3010 a simulator: neither is the network's fault, and both read as a bare number otherwise.
    public static func pushReason(_ error: Error) -> (reason: String, code: Int) {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 3000: return ("noEntitlement", nsError.code)
            case 3010: return ("simulator", nsError.code)
            default: break
            }
        }
        let found = cause(of: error)
        return (found.cause.rawValue, nsError.code)
    }

    /// `OSStatus` from the keychain read, or -1 when the store was found but its contents would not decode.
    public static func pinStoreProperties(status: Int32?) -> [String: any Sendable] {
        properties(reason: status == nil ? "undecodable" : "keychain", code: status.map(Int.init) ?? -1)
    }
}

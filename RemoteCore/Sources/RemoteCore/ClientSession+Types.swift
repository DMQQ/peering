import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case handshaking
        case confirming(code: String)
        case ready
        case failed(String)
        case disconnected

        public var holdsSession: Bool {
            switch self {
            case .connecting, .handshaking, .confirming, .ready: return true
            case .idle, .failed, .disconnected: return false
            }
        }
    }

    public struct DatagramCounts: Sendable, Equatable {
        public let received: Int
        public let fromPeer: Int
        public let refused: Int
        public let pictures: Int

        public init(received: Int, fromPeer: Int, refused: Int, pictures: Int) {
            self.received = received
            self.fromPeer = fromPeer
            self.refused = refused
            self.pictures = pictures
        }

        public var summary: String {
            "\(received) received, \(fromPeer) from the Mac, \(refused) unreadable, \(pictures) pictures"
        }
    }

    public enum Event: Sendable {
        case phase(Phase)
        case host(ServerHello)
        case catalog(CaptureCatalog)
        case video(VideoEvent)
        /// Round-trip time of a control ping in ms. Not the picture's: the control connection goes through the relay in every session.
        case latency(milliseconds: Double)

        /// Round-trip time on the lane the picture arrives on, in ms; absent when there is no datagram lane. `fromPeer` says which path answered.
        case pathLatency(milliseconds: Double, fromPeer: Bool)
        /// What the relay's datagram lane has carried, every couple of seconds while one is open.
        case datagramCounts(DatagramCounts)
        case note(String)
        /// A standing condition on the Mac the user should see, or `nil`. Unlike ``note(_:)`` it stays up until the Mac says otherwise.
        case remoteNotice(NoticePayload?)
        /// What is on the host's pasteboard, on request or pushed when it changes. A payload because it may be a picture.
        case clipboard(ClipboardPayload)
        case textFocus(TextFocus)
        case fieldState(FieldState)
        case audio(AudioEvent)
        case terminal(TerminalEvent)
        case agent(AgentEvent)
        case relayQuotaExceeded
        /// The user stopped hosting on the Mac. Sent just before the session fails, so the app
        /// can treat that failure as final rather than a drop to reconnect from.
        case hostStopped
        /// Which way the picture is now arriving, sent only when the direct path takes over or is given up; absence means the relay.
        case path(DatagramPath)
        case directPath(DirectPath)
    }

    /// Which way the picture is arriving, as this end observes it. Only this direction, since the Mac decides what to send from what it receives.
    public enum DatagramPath: Sendable, Equatable {
        case relay
        case direct
    }

    /// What the attempt at a path straight to the Mac has come to. Failures are reported, since a NAT dropping packets and a failed lookup need different fixes.
    public enum DirectPath: Sendable, Equatable {
        case notTried
        case noAddress
        case probing(peer: String)
        /// The relay named an address this end cannot open a socket to: it renders a v4-mapped source as `::ffff:a.b.c.d`, which `getaddrinfo` refuses for `AF_INET`. Folding the mapping away is the fix.
        case addressUnusable(peer: String)
        case open(peer: String)

        public var summary: String {
            switch self {
            case .notTried: return "Not tried"
            case .noAddress: return "The relay has not said where the Mac is"
            case .probing(let peer): return "Knocking on \(peer), nothing back yet"
            case .addressUnusable(let peer): return "The relay named \(peer), which this phone cannot use"
            case .open(let peer): return "Straight to \(peer)"
            }
        }
    }

    public enum VideoEvent: Sendable {
        case connecting
        case config(VideoStreamConfig)
        case frame(EncodedVideoFrame)
        case ended(String)
        case transport(VideoTransport)
    }

    public enum AudioEvent: Sendable {
        case config(AudioStreamConfig)
        case frame(EncodedAudioFrame)
    }

    public enum Target: Sendable {
        case discovered(DiscoveredHost)
        case address(host: String, port: UInt16)
        /// A previously paired Mac reached through `peeringd` by stable device ID, with the entitlement (see ``RelayEntitlement``).
        case relay(hostID: String, name: String, entitlement: RelayEntitlement)

        /// A Mac never paired with, dialled by an ID typed or scanned. A separate case because the difference is a permission: ``relay(hostID:name:entitlement:)`` is refused with no stored pin. The ID is an address, not a credential; authentication is still the six digits.
        case relayPairing(hostID: String, name: String, entitlement: RelayEntitlement)

        public var displayName: String {
            switch self {
            case .discovered(let host): return host.name
            case .address(let host, let port): return "\(host):\(port)"
            case .relay(_, let name, _), .relayPairing(_, let name, _): return name
            }
        }

        /// The Mac's device ID for targets that name one, `nil` for a literal address. The reconnect ladder reads it to tell whether it is redialling the same Mac.
        public var hostID: String? {
            switch self {
            case .discovered(let host): return host.id
            case .relay(let hostID, _, _), .relayPairing(let hostID, _, _): return hostID
            case .address: return nil
            }
        }

        var isFirstPairing: Bool {
            if case .relayPairing = self { return true }
            return false
        }
    }

    /// Why a session failed, from a closed set: ``Phase/failed(_:)`` carries a sentence that can name a Mac or an address, which analytics must never see.
    public enum FailureReason: String, Sendable, Equatable, CaseIterable {
        case busy, protocolMismatch, pinMismatch, noPinOnFile, hostIDMismatch, identity
        case handshake, pairingRefused, pairingNotSaved
        case timedOut, hostClosed, refused, transport, relay
        case hostReportedError, unresponsive, unresponsiveAfterCheck, videoLost, other

        init(_ error: Error) {
            switch error {
            case let failure as Failure: self = failure.reason
            case let failure as ClientConnection.Failure: self = FailureReason(failure)
            case is RelaySignallingError: self = .relay
            default: self = .other
            }
        }

        init(_ failure: ClientConnection.Failure) {
            switch failure {
            case .timedOut: self = .timedOut
            case .hostClosed: self = .hostClosed
            case .refused: self = .refused
            case .invalidPort, .cancelled, .transport: self = .transport
            }
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case busy
        case protocolMismatch(client: UInt16, host: UInt16)
        case commitmentMismatch
        case noServerKey
        /// The Mac answered and is not the one this device paired with: an impostor, or a Mac reset and paired again.
        case pinMismatch(hostID: String)
        /// Dialled by device ID with nothing in the pin store. Not ``pinMismatch``: there was no key to compare.
        case noPinOnFile(hostID: String)
        /// The Mac that answered through the relay is not the one whose ID was dialled. A routing check only: authentication is the code comparison.
        case hostIDMismatch(dialled: String, answered: String)
        case unexpected(MessageKind, expected: String)
        case identity(String)

        /// What to say about a network error: for an `NWError`, `localizedDescription` is `Network.NWError error 60`, not a sentence. The table is ``NetworkFailureText``.
        static func describe(_ error: Error) -> String {
            NetworkFailureText.describe(error)
        }

        var reason: FailureReason {
            switch self {
            case .busy: return .busy
            case .protocolMismatch: return .protocolMismatch
            case .pinMismatch: return .pinMismatch
            case .noPinOnFile: return .noPinOnFile
            case .hostIDMismatch: return .hostIDMismatch
            case .identity: return .identity
            case .commitmentMismatch, .noServerKey, .unexpected: return .handshake
            }
        }

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "This session is already connecting or connected."
            case .protocolMismatch(let client, let host):
                return "This Mac speaks protocol v\(host) and this app speaks v\(client). Update whichever is older."
            case .commitmentMismatch:
                // Reached only when a peer changed its contribution after seeing ours.
                return "The Mac's pairing reveal did not match its commitment."
            case .noServerKey:
                return "The Mac's certificate did not expose a public key, so it cannot be pinned."
            case .pinMismatch(let hostID):
                // The advice is part of the sentence rather than a second screen: the only way
                // forward is to forget this Mac and pair again. "pinned" is the word
                // ``HostPickerView`` looks for to give this its own title.
                return "Something at this address is not the Mac you paired with (\(hostID)). Its key does not match the key this iPhone pinned for it. If the Mac was reset, forget it here and pair again."
            case .noPinOnFile(let hostID):
                return "This iPhone has no pairing on file for that Mac (\(hostID)). The Mac still trusts this iPhone, so it will not ask to pair again: on the Mac, open Devices and forget this iPhone, then pair again."
            case .hostIDMismatch(let dialled, let answered):
                return "A different Mac answered: \(answered), not \(dialled). Check that the code you scanned or typed came from the Mac you meant."
            case .unexpected(let kind, let expected):
                return "Expected \(expected) from the Mac, got \(kind)."
            case .identity(let detail):
                return "This device's identity could not be loaded: \(detail)"
            }
        }
    }
}

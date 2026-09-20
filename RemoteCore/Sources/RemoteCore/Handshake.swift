import Foundation

/// Sent by the client as the first application-layer message on a control connection.
public struct ClientHello: Codable, Sendable, Equatable {
    /// Stable identifier for the client device, generated once per install. Used to look
    /// up its pin on the host.
    public var clientID: String
    /// Human-readable label so the host can show "Damian's iPhone".
    public var clientName: String
    /// Lets the host reject a client speaking a different protocol outright rather than
    /// failing later on an unrecognised message kind.
    public var protocolVersion: UInt16
    /// Whether the client believes it already has a usable pin for this host. Advisory
    /// only — the host decides, because only the host knows its own pin store.
    public var wantsPairing: Bool

    public init(clientID: String, clientName: String, protocolVersion: UInt16, wantsPairing: Bool) {
        self.clientID = clientID
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.wantsPairing = wantsPairing
    }
}

/// The host's reply to ``ClientHello``.
///
/// Deliberately does **not** carry the host's public key. The client takes that from the
/// TLS certificate it actually received. If the key arrived as an ordinary field here, a
/// man-in-the-middle would simply send its own and both screens would agree by
/// construction — the digits would authenticate nothing.
public struct ServerHello: Codable, Sendable, Equatable {
    public var serverID: String
    public var hostName: String
    public var protocolVersion: UInt16
    /// True when the host already holds a pin for this client, so no pairing is needed
    /// and the client can proceed straight to commands.
    public var alreadyPaired: Bool
    /// Ethernet/Wi-Fi MAC addresses of the host's physical interfaces, for Wake-on-LAN.
    /// Each entry is a colon-separated hex string ("aa:bb:cc:dd:ee:ff").
    public var macAddresses: [String]?

    public init(serverID: String, hostName: String, protocolVersion: UInt16, alreadyPaired: Bool, macAddresses: [String]? = nil) {
        self.serverID = serverID
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.alreadyPaired = alreadyPaired
        self.macAddresses = macAddresses
    }
}

/// A hash commitment, revealing nothing about the value committed to.
public struct PairingCommit: Codable, Sendable, Equatable {
    public var commitment: Data

    public init(commitment: Data) {
        self.commitment = commitment
    }
}

/// The value behind a ``PairingCommit``. Checked against the earlier commitment before
/// being used, so a peer that changed its mind after seeing the other side's contribution
/// is caught here rather than silently succeeding.
public struct PairingReveal: Codable, Sendable, Equatable {
    public var ephemeralPublicKey: Data
    public var nonce: Data

    public init(ephemeralPublicKey: Data, nonce: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

/// The user's verdict on the six digits, sent by the client (the side the human is
/// holding) after comparing the two screens.
public struct PairConfirm: Codable, Sendable, Equatable {
    public var accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

/// The host's answer: whether the pin was stored.
public struct PairResult: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// Present when `accepted` is false, so the client can say *why* rather than just
    /// failing. The user is standing there looking at two screens; a bare failure is
    /// indistinguishable from a bug.
    public var reason: String?

    public init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted
        self.reason = reason
    }
}

/// A descriptive failure the host can report without tearing the connection down.
/// A standing condition on the host, or `nil` when there is none.
///
/// `nil` rather than an empty string so "there is nothing to say" and "there is something to
/// say and it is the empty string" cannot be confused — the second is not a message.
public struct NoticePayload: Codable, Sendable, Equatable {
    public let message: String?

    /// An SF Symbol for the client to draw above the message.
    ///
    /// The host picks it because the host is the side that knows *which* thing is wrong — a
    /// sleeping screen and a disconnected one produce the same black frames and want different
    /// pictures. It is a name rather than an image for the same reason the catalogue carries
    /// title strings: the client renders what it is given, and a symbol is the cheapest thing
    /// it can be given that is still specific.
    public let symbol: String?

    public init(message: String?, symbol: String? = nil) {
        self.message = message
        self.symbol = symbol
    }
}

/// Clipboard text sent from host → client (or carried inside a ``RemoteCommand/pushClipboard``).
public struct ClipboardPayload: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// The number a ping went out with, echoed by its pong.
///
/// **A ping with no number cannot be timed, only guessed at.** The client kept one timestamp and
/// overwrote it with every ping, so a reply arriving after the next ping had gone out was measured
/// against the newer one — a round trip delayed by a second and a half reported tens of
/// milliseconds. The number is what lets a pong be matched to the question it answers, and what
/// lets one that arrives too late be thrown away instead of believed.
///
/// It travels as a payload rather than as a new message kind so that a Mac which does not read it
/// answers with an empty pong and nothing breaks. See ``ClientSession/pingIndex(answeredBy:)`` for
/// what an empty pong is taken to mean.
public struct PingPayload: Codable, Sendable, Equatable {
    public let sequence: UInt64

    public init(sequence: UInt64) {
        self.sequence = sequence
    }
}

public struct ErrorPayload: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// JSON coding for the control channel's structured payloads.
///
/// JSON rather than a binary format because these messages are small, infrequent, and
/// enormously easier to debug when something goes wrong mid-handshake — the traffic is
/// already inside TLS, so the usual argument for a compact encoding does not apply.
/// Video frames take the binary path and never come through here.
public enum MessageCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

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

    /// Whether this client can read a picture on the clipboard, in both directions.
    /// See ``ServerHello/supportsClipboardImages``, which is the same fact the other way round.
    ///
    /// **It has to be declared, because the protocol version does not distinguish the two cases.**
    /// Both this build and the one before it speak version 16, and a Mac cannot tell them apart at
    /// the door. What it *can* do is send a picture only to a client that has said it can read
    /// one. A client that has not said so is a client whose pasteboard carries text, which is
    /// exactly what it carried before any of this existed.
    ///
    /// Optional and additive: a client built before this field sends a hello that decodes with it
    /// `nil`, which reads as no.
    public var supportsClipboardImages: Bool?

    public init(
        clientID: String,
        clientName: String,
        protocolVersion: UInt16,
        wantsPairing: Bool,
        supportsClipboardImages: Bool? = nil
    ) {
        self.clientID = clientID
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.wantsPairing = wantsPairing
        self.supportsClipboardImages = supportsClipboardImages
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
    /// Whether this Mac can be asked to stop sending the picture without ending the session.
    /// See ``RemoteCommand/setVideoEnabled(_:)``.
    ///
    /// **A capability rather than a protocol version, and the difference is who gets locked
    /// out.** Every earlier change to the command set was one that every session sends, so a
    /// mixed pair failed at some unpredictable moment and a version bump turned that into an
    /// update message at the door. This command is conditional by construction: a client sends
    /// it only to a Mac that has said it can take it, and a Mac that has not is a Mac whose
    /// second tab keeps streaming rather than a Mac its owner cannot reach at all. Macs update
    /// on their own schedule, and the app has to be honest about a feature one of them does
    /// not have rather than refuse to speak to it.
    ///
    /// Optional and additive, so a Mac older than this field sends a hello that decodes with
    /// it `nil`, which reads as "no" and is the honest answer. A client must send the
    /// command only on an explicit `true`: an unknown command is a decode failure in the
    /// middle of a session, and `nil` cannot be told apart from a host too old to have heard
    /// the question.
    public var supportsVideoPause: Bool?

    /// Whether this Mac can carry a picture on the clipboard, in both directions.
    /// See ``RemoteCommand/pushClipboardImage(png:)``.
    ///
    /// **A capability for the same reason the one above is, and the reason is starker here.** The
    /// command that pushes a picture is one an older Mac cannot decode, and the failure would
    /// land in the middle of a session: a user copies a screenshot, taps push, and the session
    /// dies rather than saying the Mac is too old. Gated, an un-updated Mac simply keeps carrying
    /// text, which is what it did before, and the app can say so.
    ///
    /// It covers *both* directions rather than one. A Mac that can receive a picture can send
    /// one, since it is the same encoder and the same pasteboard code, so a second flag would be
    /// two names for one fact and a way for them to disagree.
    public var supportsClipboardImages: Bool?

    public init(
        serverID: String,
        hostName: String,
        protocolVersion: UInt16,
        alreadyPaired: Bool,
        macAddresses: [String]? = nil,
        supportsVideoPause: Bool? = nil,
        supportsClipboardImages: Bool? = nil
    ) {
        self.serverID = serverID
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.alreadyPaired = alreadyPaired
        self.macAddresses = macAddresses
        self.supportsVideoPause = supportsVideoPause
        self.supportsClipboardImages = supportsClipboardImages
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

/// What is on a pasteboard, in the one shape both directions carry it in.
///
/// **Text and a picture are the same message with a different payload**, rather than two messages
/// that happen to be adjacent. That is not tidiness: the two ends of this protocol have to agree
/// about *when* a pasteboard changed and about which one of them is allowed to act on it, and
/// those rules are identical for a line of text and for a screenshot. What differs is only how the
/// contents travel, and that is the business of ``ClipboardTransfer``.
public struct ClipboardPayload: Codable, Sendable, Equatable {
    /// Which thing is on the pasteboard.
    ///
    /// **A field rather than "whichever of the two is set".** Nothing about the payload's shape
    /// would stop both being present, and the two ends would then disagree about which one wins
    /// depending on the order each happened to check them in. A payload that says what it is
    /// cannot be read two ways.
    public enum Kind: String, Codable, Sendable {
        case text
        case image
    }

    public var kind: Kind
    /// The text, for a `.text` payload.
    public var text: String?
    /// The picture, for an `.image` payload, as **PNG in both directions**.
    ///
    /// One format rather than the type the pasteboard happened to hold, which is what makes this
    /// readable without a second exchange: macOS puts a screenshot on the pasteboard as TIFF and a
    /// browser puts a copied image there as often as not the same, and iOS reads neither. PNG is
    /// the format both ends can produce and both can read, and it is lossless, so a picture copied
    /// across does not degrade each time it is copied again.
    public var image: Data?

    public init(kind: Kind, text: String? = nil, image: Data? = nil) {
        self.kind = kind
        self.text = text
        self.image = image
    }

    public static func text(_ text: String) -> ClipboardPayload {
        ClipboardPayload(kind: .text, text: text)
    }

    public static func image(_ png: Data) -> ClipboardPayload {
        ClipboardPayload(kind: .image, image: png)
    }

    /// The picture, if there is one and it is within the size both ends promise to carry.
    ///
    /// The check belongs here rather than at the point of use because it is the same question at
    /// both ends and the answer has to be the same one. See ``ClipboardLimits/maxImageBytes``.
    public var carriedImage: Data? {
        guard kind == .image, let image, image.count <= ClipboardLimits.maxImageBytes else { return nil }
        return image
    }

    /// Reads a payload written before there was a kind.
    ///
    /// **The synthesised decoder would refuse an older Mac's clipboard**, which is the entire
    /// text of the feature for anybody whose Mac has not updated: the payload it sends is
    /// `{"text": "..."}` with no `kind` in it, the decode would fail, and a line of text that
    /// used to arrive would silently stop. Absent means text, because text is the only thing that
    /// could have been sent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text)
        image = try container.decodeIfPresent(Data.self, forKey: .image)
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

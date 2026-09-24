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
    /// only: the host decides, because only the host knows its own pin store.
    public var wantsPairing: Bool

    /// Whether this client can read a picture on the clipboard, in both directions.
    /// See ``ServerHello/supportsClipboardImages``, which is the same fact the other way round.
    ///
    /// Declared rather than implied by the version: both this build and the one before it speak
    /// version 16, so a Mac cannot tell them apart at the door and sends a picture only to a client
    /// that has said it can read one. Optional and additive, so an older client's hello decodes with
    /// it `nil`, which reads as no.
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
/// Deliberately does not carry the host's public key, which the client takes from the TLS
/// certificate it actually received: a man-in-the-middle cannot send its own and have both screens
/// agree by construction.
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
    /// A capability rather than a version bump, so an older Mac keeps streaming rather than failing
    /// mid-session. Optional and additive, so an older Mac decodes with it `nil`, which reads as
    /// "no"; the client sends the command only on an explicit `true`, an unknown command being a
    /// decode failure in the middle of a session.
    public var supportsVideoPause: Bool?

    /// Whether this Mac can carry a picture on the clipboard, in both directions.
    /// See ``RemoteCommand/pushClipboardImage(png:)``.
    ///
    /// A capability on the same argument, one flag covering both directions: a Mac that can receive
    /// a picture can send one, being the same encoder and pasteboard code. Optional and additive, so
    /// `nil` reads as "no", and the command is sent only on an explicit `true`.
    public var supportsClipboardImages: Bool?

    /// Whether this Mac can composite several sources into one picture.
    ///
    /// A capability rather than a version bump: `CaptureSource` gains a case an older Mac cannot
    /// decode, but it is only ever sent by a client and only to a Mac that has said it understands
    /// it. Optional and additive, so `nil` reads as "no", and a mosaic is sent only on an explicit
    /// `true`.
    public var supportsMosaic: Bool?

    /// Whether this Mac can photograph its running applications for the picker's grid.
    /// See ``RemoteCommand/refreshSourceThumbnails``.
    ///
    /// A capability on the same argument as the three above: an un-updated Mac throws on the
    /// command, which is sent when the Apps panel opens. Only the asking needs the flag,
    /// ``CaptureSourceDescriptor/thumbnail`` being an optional field read with `decodeIfPresent`.
    /// Optional and additive, so `nil` reads as "no", and the command is sent only on a `true`.
    public var supportsSourceThumbnails: Bool?

    /// Whether this Mac will rotate a virtual display's shape to match the phone's own
    /// orientation. See ``RemoteCommand/reportDeviceOrientation(isLandscape:)``.
    ///
    /// A capability on the same argument as the three above: the command is harmless to an old
    /// Mac's *decoder* only because it is never sent to one. Optional and additive, so `nil`
    /// reads as "no", and the client keeps quiet about its orientation rather than have it land
    /// on a Mac with nothing to do with it.
    public var supportsDeviceOrientation: Bool?

    public init(
        serverID: String,
        hostName: String,
        protocolVersion: UInt16,
        alreadyPaired: Bool,
        macAddresses: [String]? = nil,
        supportsVideoPause: Bool? = nil,
        supportsClipboardImages: Bool? = nil,
        supportsMosaic: Bool? = nil,
        supportsSourceThumbnails: Bool? = nil,
        supportsDeviceOrientation: Bool? = nil
    ) {
        self.serverID = serverID
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.alreadyPaired = alreadyPaired
        self.macAddresses = macAddresses
        self.supportsVideoPause = supportsVideoPause
        self.supportsClipboardImages = supportsClipboardImages
        self.supportsMosaic = supportsMosaic
        self.supportsSourceThumbnails = supportsSourceThumbnails
        self.supportsDeviceOrientation = supportsDeviceOrientation
    }
}

/// A hash commitment, revealing nothing about the value committed to.
public struct PairingCommit: Codable, Sendable, Equatable {
    public var commitment: Data

    public init(commitment: Data) {
        self.commitment = commitment
    }
}

/// The value behind a ``PairingCommit``, checked against the earlier commitment before use, so a
/// peer that changed its mind after seeing the other side's contribution is caught here.
public struct PairingReveal: Codable, Sendable, Equatable {
    public var ephemeralPublicKey: Data
    public var nonce: Data

    public init(ephemeralPublicKey: Data, nonce: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

/// The user's verdict on the six digits, sent by the client after comparing the two screens.
public struct PairConfirm: Codable, Sendable, Equatable {
    public var accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

/// The host's answer: whether the pin was stored.
public struct PairResult: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// Present when `accepted` is false, so the client can say why: a bare failure beside two
    /// screens is indistinguishable from a bug.
    public var reason: String?

    public init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted
        self.reason = reason
    }
}

/// A descriptive failure the host can report without tearing the connection down.
/// A standing condition on the host, or `nil` when there is none.
///
/// `nil` rather than an empty string, so "there is nothing to say" is not a message.
public struct NoticePayload: Codable, Sendable, Equatable {
    public let message: String?

    /// An SF Symbol for the client to draw above the message, picked by the host, which is the side
    /// that knows which thing is wrong: a sleeping screen and a disconnected one produce the same
    /// black frames and want different pictures.
    public let symbol: String?

    public init(message: String?, symbol: String? = nil) {
        self.message = message
        self.symbol = symbol
    }
}

/// What is on a pasteboard, in the one shape both directions carry it in.
///
/// Text and a picture are the same message with a different payload: the two ends have to agree
/// about when a pasteboard changed and which of them may act on it, and those rules are identical
/// for a line of text and for a screenshot. Only how the contents travel differs, which is the
/// business of ``ClipboardTransfer``.
public struct ClipboardPayload: Codable, Sendable, Equatable {
    /// Which thing is on the pasteboard.
    ///
    /// A field rather than "whichever of the two is set": nothing about the payload's shape stops
    /// both being present, and the two ends would then disagree about which wins.
    public enum Kind: String, Codable, Sendable {
        case text
        case image
    }

    public var kind: Kind
    /// The text, for a `.text` payload.
    public var text: String?
    /// The picture, for an `.image` payload, as PNG in both directions.
    ///
    /// One format rather than whatever the pasteboard held, which is what makes this readable
    /// without a second exchange: macOS puts a screenshot there as TIFF, which iOS reads not at all.
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
    /// The same question at both ends, so the answer belongs in one place.
    /// See ``ClipboardLimits/maxImageBytes``.
    public var carriedImage: Data? {
        guard kind == .image, let image, image.count <= ClipboardLimits.maxImageBytes else { return nil }
        return image
    }

    /// Reads a payload written before there was a kind.
    ///
    /// The synthesised decoder would refuse an older Mac's clipboard: it sends `{"text": "..."}`
    /// with no `kind` in it, so an absent kind means text, the only thing that could have been sent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text)
        image = try container.decodeIfPresent(Data.self, forKey: .image)
    }
}

/// The number a ping went out with, echoed by its pong.
///
/// A ping with no number cannot be timed: a reply arriving after the next ping had gone out was
/// measured against the newer one. The number is what lets a pong be matched to the question it
/// answers, and one that arrives too late be thrown away instead of believed.
///
/// It travels as a payload rather than as a new message kind, so a Mac which does not read it
/// answers with an empty pong and nothing breaks. See ``ClientSession/pingIndex(answeredBy:)``.
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
/// These messages are small, infrequent, and the traffic is already inside TLS. Video frames take
/// the binary path and never come through here.
public enum MessageCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

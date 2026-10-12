import Foundation

/// The first frame on a connection is always ``connectionRole``; see ``ConnectionRole``.
public enum MessageKind: UInt8, Sendable, CaseIterable {
    case connectionRole = 0x01

    case clientHello = 0x02
    case serverHello = 0x03

    case pairConfirm = 0x04
    case pairResult = 0x05
    /// Hash commitment to an ephemeral public key, sent *before* any reveal: the order is the security
    /// property, since without it an attacker can grind a keypair until it produces the digits the
    /// host is about to display. See ``PairingSAS``.
    case pairCommit = 0x0E
    case pairReveal = 0x0F

    case command = 0x06
    case catalog = 0x07
    case setCaptureSource = 0x08
    case ping = 0x0B
    case pong = 0x0C
    case error = 0x0D

    case videoConfig = 0x09
    case videoFrame = 0x0A

    /// A standing host condition the client should say out loud, not an ``error`` (which ends the session). A sleeping display is the case: healthy frames, all black. `nil` clears.
    case notice = 0x10

    case clipboardContent = 0x11

    case audioConfig = 0x13

    case audioFrame = 0x14

    case terminalRequest = 0x15

    case terminalEvent = 0x16

    /// Fallback for a network that blocks the video transport: the ``videoFrame`` bytes cut to fit a control message.
    case videoChunk = 0x17

    /// Client asks the host to move video between transport and control channel. The host cannot tell a datagram lost at the first router, so the end that sees nothing arriving speaks.
    case videoTransport = 0x18

    /// Carries nothing; a client asks only on a relayed session.
    case videoKeyRequest = 0x19

    /// Travels inside the control channel's TLS session, so the relay only forwards ciphertext.
    case videoKey = 0x1A
    /// Opening it proves the datagram came from the peer and not from someone spoofing a source address, which the relay's introduction cannot vouch for.
    case directProbe = 0x1B
    /// The Mac's keyboard focus moved. JSON-encoded ``TextFocus``. Sent only to a client that
    /// declared ``ClientHello/supportsTextFocus``.
    case textFocus = 0x1C
    /// What the focused text field holds and where its caret is. JSON-encoded ``FieldState``. Sent only
    /// to a client that declared ``ClientHello/supportsFieldState``.
    case fieldState = 0x1D

    /// An authenticated client's agent chat request. JSON-encoded ``AgentRequest``. Sent only to a
    /// Mac that declared ``ServerHello/supportsAgentChat``.
    case agentRequest = 0x1E

    /// Agent session listings, stream events and replays from the host. JSON-encoded ``AgentEvent``.
    /// Sent only to a client that declared ``ClientHello/supportsAgentChat``.
    case agentEvent = 0x1F

    /// The phone's web preview asking the Mac to fetch from its own loopback. JSON-encoded ``PreviewProxyCommand``.
    case previewRequest = 0x20

    /// The answer, in pieces. JSON-encoded ``PreviewProxyEvent``.
    case previewEvent = 0x21

    /// Where the Mac's pointer is after something other than this client moved it. JSON-encoded ``NormalizedPoint``. Sent only to a client that declared ``ClientHello/supportsPointerReport``.
    case pointerReport = 0x22

    /// The client app left or returned to the foreground. JSON-encoded ``ClientStatePayload``. Sent only to a host that declared ``ServerHello/supportsClientState``.
    case clientState = 0x23
}

public enum FramingError: Error, LocalizedError, Equatable, Sendable {
    /// Thrown before buffering the payload, so a hostile length cannot exhaust memory.
    case frameTooLarge(declared: UInt32)
    case zeroLengthFrame
    /// The kind byte was not a known ``MessageKind``. Almost always means the peers are
    /// speaking different protocol versions; failing loudly beats silently skipping bytes.
    case unknownKind(UInt8)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let declared):
            return "The Mac sent a message this app cannot read (\(declared) bytes). The two ends may be running different versions."
        case .zeroLengthFrame:
            return "The Mac sent a malformed message. The two ends may be running different versions."
        case .unknownKind:
            return "The Mac sent a message this app does not recognise. Update whichever end is older."
        }
    }
}

public struct Frame: Equatable, Sendable {
    public let kind: MessageKind
    public let payload: Data

    public init(kind: MessageKind, payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }
}

/// ```
/// ┌──────────────┬─────────┬─────────────────────┐
/// │ u32 length   │ u8 kind │ payload (length-1)  │
/// │ big-endian   │         │                     │
/// └──────────────┴─────────┴─────────────────────┘
/// ```
/// `length` counts the kind byte plus the payload. Feed it whatever bytes the transport hands over:
/// TCP delivers an arbitrary byte window, so frames arrive split, coalesced, or several at a time.
public struct FrameDecoder {
    /// Enforced on the declared length before buffering.
    public static let maxFrameLength: UInt32 = 16 * 1024 * 1024

    private var buffer: [UInt8] = []
    private var readIndex = 0

    /// The largest frame this decoder will buffer; lowered for a peer that has not authenticated.
    public var frameLimit: UInt32 = FrameDecoder.maxFrameLength

    public init() {}

    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append<D: DataProtocol>(_ data: D) {
        buffer.append(contentsOf: data)
    }

    public mutating func next() throws -> Frame? {
        guard bufferedByteCount >= 4 else {
            compactIfWorthwhile()
            return nil
        }

        let length = UInt32(buffer[readIndex]) << 24
            | UInt32(buffer[readIndex + 1]) << 16
            | UInt32(buffer[readIndex + 2]) << 8
            | UInt32(buffer[readIndex + 3])

        guard length >= 1 else { throw FramingError.zeroLengthFrame }
        guard length <= frameLimit else {
            throw FramingError.frameTooLarge(declared: length)
        }

        let total = 4 + Int(length)
        guard bufferedByteCount >= total else {
            compactIfWorthwhile()
            return nil
        }

        let rawKind = buffer[readIndex + 4]
        guard let kind = MessageKind(rawValue: rawKind) else {
            throw FramingError.unknownKind(rawKind)
        }

        let payload = Data(buffer[(readIndex + 5)..<(readIndex + total)])
        readIndex += total
        compactIfWorthwhile()
        return Frame(kind: kind, payload: payload)
    }

    private mutating func compactIfWorthwhile() {
        guard readIndex > 0 else { return }
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 64 * 1024 && readIndex * 2 >= buffer.count {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

public enum FrameEncoder {
    public static func encode(_ frame: Frame) -> Data {
        encode(kind: frame.kind, payload: frame.payload)
    }

    public static func encode(kind: MessageKind, payload: Data = Data()) -> Data {
        let length = UInt32(payload.count + 1) // kind byte + payload
        var out = Data(capacity: 4 + Int(length))
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }
}

/// Which stream a connection carries. Control and video ride separate TCP connections so a 200 KB
/// keyframe cannot sit in front of the next mouse move: control latency is what the user feels.
public enum ConnectionRole: UInt8, Codable, Sendable {
    case control = 1
    case video = 2
}

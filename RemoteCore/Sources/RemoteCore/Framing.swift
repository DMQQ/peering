import Foundation

/// The type of a wire message, carried as the first byte of every frame.
///
/// The first frame on a connection is always ``connectionRole``; see ``ConnectionRole``.
public enum MessageKind: UInt8, Sendable, CaseIterable {
    /// Sent first on every connection to declare whether it carries control or video.
    case connectionRole = 0x01

    // Handshake (unauthenticated phase)
    case clientHello = 0x02
    case serverHello = 0x03

    // Pairing
    case pairConfirm = 0x04
    case pairResult = 0x05
    /// Hash commitment to an ephemeral public key, sent *before* any reveal: the order is the security
    /// property, since without it an attacker can grind a keypair until it produces the digits the
    /// host is about to display. See ``PairingSAS``.
    case pairCommit = 0x0E
    case pairReveal = 0x0F

    // Control channel
    case command = 0x06
    case catalog = 0x07
    case setCaptureSource = 0x08
    case ping = 0x0B
    case pong = 0x0C
    case error = 0x0D

    // Video channel
    case videoConfig = 0x09
    case videoFrame = 0x0A

    /// A standing condition on the host that the client should say out loud, distinct from ``error``,
    /// which ends the session: nothing is broken, but what the phone is looking at is not what it
    /// thinks. A sleeping display is the case this exists for, healthy frames arriving all black.
    /// Carries `nil` to clear.
    case notice = 0x10

    /// The host's clipboard, sent in response to a ``RemoteCommand/requestClipboard`` command
    /// or pushed proactively when it changes. Carries a ``ClipboardPayload``.
    case clipboardContent = 0x11

    /// Configuration for the audio stream that follows on the video connection, sent once per stream
    /// start, ahead of the first ``audioFrame``. JSON-encoded ``AudioStreamConfig``.
    case audioConfig = 0x13

    /// One chunk of raw PCM audio. Fixed binary header + interleaved Float32 samples.
    /// Layout matches ``EncodedAudioFrame``.
    case audioFrame = 0x14

    /// An authenticated client's terminal lifecycle/input request.
    case terminalRequest = 0x15

    /// Terminal snapshots, output, attention signals, and lifecycle events from the host.
    case terminalEvent = 0x16

    /// One piece of a video payload travelling the control channel. See ``VideoChunk``.
    ///
    /// A fallback rather than a second stream: the same bytes ``videoFrame`` carries, cut into pieces
    /// a control message can hold, for a network that blocks the video transport.
    case videoChunk = 0x17

    /// An authenticated client asking the host to move video between the transport it prefers and the
    /// control channel. Carries a ``VideoTransportRequest``. The host cannot tell a datagram that
    /// arrived from one dropped at the first router, while the client sees nothing arriving, so the
    /// end with the evidence is the end that speaks.
    case videoTransport = 0x18

    /// An authenticated client asking the Mac for the secret that seals video datagrams.
    ///
    /// Carries nothing: the question is "may this session send video over the relay's datagram path",
    /// and everything needed to answer it is known to both ends. A client asks only on a relayed
    /// session, and the Mac answers only for the client that asked.
    case videoKeyRequest = 0x19

    /// The Mac's answer to a ``videoKeyRequest``: the session's video secret. Carries a
    /// ``VideoKeyGrant``.
    ///
    /// It travels inside the control channel's TLS session, authenticated at both ends by the pairing,
    /// so the relay, which terminates neither end, only ever forwards ciphertext it has no key for.
    case videoKey = 0x1A
    /// A sealed datagram sent only to see whether a direct path between the two ends is open.
    ///
    /// Carries nothing, and opening it is the point: it proves the datagram came from the peer, not
    /// from anyone who can write a source address into a packet, which is what the relay's
    /// introduction cannot vouch for. The address it arrives from is then trusted to send the picture.
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
}

public enum FramingError: Error, LocalizedError, Equatable, Sendable {
    /// The declared length exceeded ``FrameDecoder/maxFrameLength``. Thrown *before*
    /// any attempt to buffer the payload, so a hostile length field cannot exhaust memory.
    case frameTooLarge(declared: UInt32)
    /// A frame must carry at least the kind byte, so a length below 1 is malformed.
    case zeroLengthFrame
    /// The kind byte was not a known ``MessageKind``. Almost always means the peers are
    /// speaking different protocol versions; failing loudly beats silently skipping bytes.
    case unknownKind(UInt8)

    /// A sentence for the user, since this reaches one.
    ///
    /// A framing failure is a protocol fault rather than a network one: the bytes arrived and did not
    /// make sense, so none of these tells the user to try again. The numbers are kept where they are
    /// the point of the sentence.
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

/// A single decoded wire message.
public struct Frame: Equatable, Sendable {
    public let kind: MessageKind
    public let payload: Data

    public init(kind: MessageKind, payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }
}

/// Incremental decoder for the wire format:
///
/// ```
/// ┌──────────────┬─────────┬─────────────────────┐
/// │ u32 length   │ u8 kind │ payload (length-1)  │
/// │ big-endian   │         │                     │
/// └──────────────┴─────────┴─────────────────────┘
/// ```
///
/// `length` counts the kind byte plus the payload. Feed it whatever bytes the transport hands over:
/// TCP delivers an arbitrary byte window, so frames arrive split, coalesced, or several at a time.
public struct FrameDecoder {
    /// Hard ceiling on a single frame. Enforced on the *declared* length before buffering,
    /// so a corrupt or hostile header is rejected instead of allocating gigabytes.
    public static let maxFrameLength: UInt32 = 16 * 1024 * 1024

    private var buffer: [UInt8] = []
    /// Start of the not-yet-consumed region. Avoids O(n) `removeFirst` per frame.
    private var readIndex = 0

    public init() {}

    /// Bytes received but not yet consumed. Exposed for tests and diagnostics.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append<D: DataProtocol>(_ data: D) {
        buffer.append(contentsOf: data)
    }

    /// Returns the next complete frame, or `nil` if more bytes are needed. Call repeatedly until it
    /// returns `nil`. Throws only on genuinely malformed input, after which the stream is unusable.
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
        guard length <= Self.maxFrameLength else {
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

    /// Drop the consumed prefix once it is a meaningful share of the buffer: a long-lived decoder
    /// then neither grows without bound nor compacts on every frame.
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

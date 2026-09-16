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
    /// Hash commitment to an ephemeral public key, sent *before* any reveal.
    ///
    /// The order is the security property: see ``PairingSAS``. Without it an active
    /// attacker can grind a keypair until its own contribution produces the digits the
    /// real host is about to display, and the two screens agree by construction.
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

    /// A standing condition on the host that the client should say out loud.
    ///
    /// Distinct from ``error``, which ends the session. This is the middle case the protocol
    /// did not have: nothing is broken — the control channel is fine, the video channel is
    /// fine — but what the phone is looking at is not what it thinks. A sleeping display is
    /// the case this exists for: the stream is healthy, the frames are arriving, and they are
    /// all black, which from the phone is indistinguishable from a broken camera.
    ///
    /// Carries `nil` to clear.
    case notice = 0x10

    /// The host's clipboard, sent in response to a ``RemoteCommand/requestClipboard`` command
    /// or pushed proactively when it changes. Carries a ``ClipboardPayload``.
    case clipboardContent = 0x11

    /// Configuration for the audio stream that follows on the video connection.
    ///
    /// Sent once per stream start, ahead of the first ``audioFrame``. JSON-encoded
    /// ``AudioStreamConfig``, matching the convention used for ``videoConfig``.
    case audioConfig = 0x13

    /// One chunk of raw PCM audio. Fixed binary header + interleaved Float32 samples.
    /// Layout matches ``EncodedAudioFrame``.
    case audioFrame = 0x14

    /// An authenticated client's terminal lifecycle/input request.
    case terminalRequest = 0x15

    /// Terminal snapshots, output, attention signals, and lifecycle events from the host.
    case terminalEvent = 0x16
}

public enum FramingError: Error, Equatable, Sendable {
    /// The declared length exceeded ``FrameDecoder/maxFrameLength``. Thrown *before*
    /// any attempt to buffer the payload, so a hostile length field cannot exhaust memory.
    case frameTooLarge(declared: UInt32)
    /// A frame must carry at least the kind byte, so a length below 1 is malformed.
    case zeroLengthFrame
    /// The kind byte was not a known ``MessageKind``. Almost always means the peers are
    /// speaking different protocol versions; failing loudly beats silently skipping bytes.
    case unknownKind(UInt8)
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
/// `length` counts the kind byte plus the payload.
///
/// Feed it whatever bytes the transport hands over — it makes no assumptions about
/// message boundaries, which is the whole point. TCP delivers an arbitrary byte window,
/// so frames arrive split, coalesced, or several at a time.
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

    /// Returns the next complete frame, or `nil` if more bytes are needed.
    ///
    /// Call repeatedly until it returns `nil` — a single read may deliver several frames.
    /// Throws only on genuinely malformed input, after which the stream is unusable.
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

    /// Drop the consumed prefix once it is a meaningful share of the buffer, so a
    /// long-lived decoder neither grows without bound nor compacts on every frame.
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

/// Which stream a connection carries.
///
/// Control and video ride separate TCP connections so a 200 KB keyframe cannot sit in
/// front of the next mouse move. Control latency is what the user feels.
public enum ConnectionRole: UInt8, Codable, Sendable {
    case control = 1
    case video = 2
}

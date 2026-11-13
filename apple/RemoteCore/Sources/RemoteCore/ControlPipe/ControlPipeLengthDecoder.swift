import Foundation

/// Cuts the relay's byte stream back into the pipe's frames: each is a four byte big-endian length and then that many bytes.
struct ControlPipeLengthDecoder {
    /// Far above any frame this end sends, so a hostile length cannot make this end buffer without limit.
    static let maxFrameSize = 64 * 1024

    private var buffer = Data()

    static func wrap(_ frame: ControlPipeFrame) -> Data {
        let body = frame.encoded()
        var out = Data(capacity: body.count + 4)
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: body.count >> shift)) }
        out.append(body)
        return out
    }

    /// The whole frames now available. Throws on a length no sender of this pipe would write, after which the stream is not trusted.
    mutating func feed(_ bytes: Data) throws -> [ControlPipeFrame] {
        buffer.append(bytes)
        var frames: [ControlPipeFrame] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrameSize else { throw ControlPipeError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: start + 4..<start + 4 + length)
            buffer = Data(buffer.dropFirst(4 + length))
            guard let frame = ControlPipeFrame.decode(body) else { throw ControlPipeError.malformed }
            frames.append(frame)
        }
        return frames
    }
}

enum ControlPipeError: Error, Equatable {
    case frameTooLarge(Int)
    case malformed
}

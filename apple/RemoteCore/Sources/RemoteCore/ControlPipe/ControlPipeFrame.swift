import Foundation

/// One piece of the control connection's byte stream, or the receiver saying how much of it has arrived. The TLS session rides on these bytes, so a carrier that dies can be replaced and the stream goes on from where the receiver last said.
public enum ControlPipeFrame: Equatable, Sendable {
    case data(offset: UInt64, payload: Data)
    case ack(upTo: UInt64)

    private static let dataTag: UInt8 = 0
    private static let ackTag: UInt8 = 1
    private static let headerSize = 9

    public func encoded() -> Data {
        var out = Data()
        switch self {
        case .data(let offset, let payload):
            out.append(Self.dataTag)
            out.append(contentsOf: Self.bytes(of: offset))
            out.append(payload)
        case .ack(let upTo):
            out.append(Self.ackTag)
            out.append(contentsOf: Self.bytes(of: upTo))
        }
        return out
    }

    public static func decode(_ bytes: Data) -> ControlPipeFrame? {
        let bytes = Data(bytes)
        guard bytes.count >= headerSize else { return nil }
        let offset = bytes[1..<headerSize].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch bytes[0] {
        case dataTag: return .data(offset: offset, payload: bytes.suffix(from: headerSize))
        case ackTag where bytes.count == headerSize: return .ack(upTo: offset)
        default: return nil
        }
    }

    private static func bytes(of value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

import Foundation

/// The receiving half of the control pipe: hands the stream on in order, once, whatever the carriers duplicated, reordered or resent.
public struct ControlPipeReceiver: Sendable {
    static let maxHeldSegments = 64

    private var next: UInt64 = 0
    private var held: [UInt64: Data] = [:]

    public init() {}

    /// Everything before this has been handed on.
    public var ackPoint: UInt64 { next }

    /// The bytes that are now in order and new, possibly none.
    public mutating func receive(offset: UInt64, payload: Data) -> Data {
        let end = offset + UInt64(payload.count)
        guard end > next else { return Data() }
        if offset > next {
            if held.count < Self.maxHeldSegments { held[offset] = payload }
            return Data()
        }
        var out = payload.suffix(from: payload.startIndex + Int(next - offset))
        next = end
        while let (start, segment) = held.first(where: { $0.key <= next }) {
            held[start] = nil
            let segmentEnd = start + UInt64(segment.count)
            guard segmentEnd > next else { continue }
            out.append(segment.suffix(from: segment.startIndex + Int(next - start)))
            next = segmentEnd
        }
        return Data(out)
    }
}

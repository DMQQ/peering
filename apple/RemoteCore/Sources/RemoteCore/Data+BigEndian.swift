import Foundation

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readBigEndianUInt16(at index: Index) -> UInt16 {
        var value: UInt16 = 0
        for offset in 0..<2 {
            value = (value << 8) | UInt16(self[index + offset])
        }
        return value
    }
}

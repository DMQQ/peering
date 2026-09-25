import AppKit
import CoreImage.CIFilterBuiltins

/// Grouped as `123 456`. Six unbroken digits are harder to compare by eye.
func formattedPairingCode(_ code: String) -> String {
    guard code.count == 6 else { return code }
    let middle = code.index(code.startIndex, offsetBy: 3)
    return "\(code[code.startIndex..<middle]) \(code[middle...])"
}

/// Draws whatever `PairingPayload` encoded, so the strings on this side and the ones the iPhone
/// parses are produced by one implementation rather than two that agree by hand.
func qrCodeImage(encoding payload: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: .init(scaleX: 9, y: 9)) else {
        return nil
    }
    let representation = NSCIImageRep(ciImage: output)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
}

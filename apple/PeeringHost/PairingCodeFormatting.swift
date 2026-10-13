import AppKit
import CoreImage.CIFilterBuiltins

func formattedPairingCode(_ code: String) -> String {
    guard code.count == 6 else { return code }
    let middle = code.index(code.startIndex, offsetBy: 3)
    return "\(code[code.startIndex..<middle]) \(code[middle...])"
}

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

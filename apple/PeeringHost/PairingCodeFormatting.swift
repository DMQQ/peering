import AppKit
import CoreImage.CIFilterBuiltins

func formattedPairingCode(_ code: String) -> String {
    guard code.count == 6 else { return code }
    let middle = code.index(code.startIndex, offsetBy: 3)
    return "\(code[code.startIndex..<middle]) \(code[middle...])"
}

/// Rendered once per payload into a bitmap. Wrapped in an `NSCIImageRep`, the code went back through Core Image on every
/// draw, and the GPU shader variants that left behind were the largest single item in the idle host's heap.
@MainActor
func qrCodeImage(encoding payload: String) -> NSImage? {
    if let cached = QRCodeCache.images.object(forKey: payload as NSString) { return cached }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: .init(scaleX: 9, y: 9)),
          let bitmap = QRCodeCache.context.createCGImage(output, from: output.extent)
    else {
        return nil
    }
    let image = NSImage(cgImage: bitmap, size: output.extent.size)
    QRCodeCache.images.setObject(image, forKey: payload as NSString)
    return image
}

@MainActor
private enum QRCodeCache {
    /// On the CPU: a few black squares do not need a GPU pipeline compiled for them.
    static let context = CIContext(options: [.useSoftwareRenderer: true])
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4
        return cache
    }()
}

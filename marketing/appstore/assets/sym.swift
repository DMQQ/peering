import AppKit
let names = ["laptopcomputer","bolt.fill","arrow.up.arrow.down","doc.on.clipboard","arrow.triangle.2.circlepath","desktopcomputer","square.grid.2x2","keyboard","face.smiling","command","person.crop.circle.badge.xmark","faceid","dot.radiowaves.left.and.right","bell.badge","lock.fill","network","speaker.wave.2.fill"]
for n in names {
    guard let img = NSImage(systemSymbolName: n, accessibilityDescription: nil) else { print("missing", n); continue }
    let cfg = NSImage.SymbolConfiguration(pointSize: 120, weight: .semibold)
    let s = img.withSymbolConfiguration(cfg)!
    let size = s.size
    let out = NSImage(size: size)
    out.lockFocus()
    NSColor.white.set()
    s.draw(in: NSRect(origin: .zero, size: size))
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    out.unlockFocus()
    let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "assets/sym/\(n).png"))
}

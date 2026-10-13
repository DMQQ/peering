import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension ScreenCaptureSourceResolver {
    /// Built from catalogue-time geometry, which goes stale when a window moves; the input layer should prefer the per-frame content rect from `CaptureEngine`.
    func inputTransform(for source: CaptureSource) -> InputTransform {
        guard let content = lock.withLock({ isStale ? nil : snapshot }) else { return .degenerate }

        switch source {
        case .display(let id):
            guard content.displays.contains(where: { $0.displayID == id }) else { return .degenerate }
            let bounds = CGDisplayBounds(id)
            let pixelWidth = CGDisplayPixelsWide(id)
            let pixelHeight = CGDisplayPixelsHigh(id)
            guard bounds.width > 0, pixelWidth > 0 else { return .degenerate }

            return InputTransform(
                origin: bounds.origin,
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                pointPixelScale: CGFloat(pixelWidth) / bounds.width
            )

        case .application(let pid):
            let owned = content.windows.filter { $0.owningApplication?.processID == pid }
            return transform(for: Self.unionFrame(of: owned))

        case .window(let id):
            let window = content.windows.first { $0.windowID == id }
            return transform(for: window?.frame)

        case .mosaic:
            // A tap's tile decides the machine coordinate, and the host refuses input while a mosaic is the source. See ``VideoCoordinator``'s input guard.
            return .degenerate
        }
    }

    private func transform(for rect: CGRect?) -> InputTransform {
        guard let rect, rect.width > 0, rect.height > 0 else { return .degenerate }
        let scale = Self.backingScale(for: rect)
        return InputTransform(
            origin: rect.origin,
            pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale),
            pointPixelScale: scale
        )
    }

    /// 2.0 on Retina, but also the odd ratios a scaled 4K display produces.
    static func backingScale(for rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 16, &ids, &count) == .success, count > 0 else { return 1 }

        let bounds = CGDisplayBounds(ids[0])
        guard bounds.width > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(ids[0])) / bounds.width
    }

    /// `NSScreen` is the only source of names (CoreGraphics gives a model number). The host's own virtual display has no `NSScreen`, so it falls back to ``VirtualDisplay/name(for:)``.
    static func screenName(for displayID: CGDirectDisplayID) -> String? {
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
        return screen?.localizedName ?? VirtualDisplay.name(for: displayID)
    }
}

extension InputTransform {
    /// Zero-sized rather than `nil`: capture never starts for a source not in the catalogue, so a throwing accessor would force callers to handle an impossible case.
    static let degenerate = InputTransform(origin: .zero, pixelSize: .zero, pointPixelScale: 1)
}

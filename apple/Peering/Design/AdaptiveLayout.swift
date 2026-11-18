import PeeringKit
import SwiftUI
import UIKit

/// Shared layout decisions for readable-column screens. An iPad does not supply a phone's line length, so these cap the column width.
enum AdaptiveLayout {
    static let contentMaxWidth: CGFloat = 760

    /// The column's width in a regular-width layout (an iPad detail pane or a sideways iPhone).
    static let wideContentMaxWidth: CGFloat = 920

    static var deviceSymbol: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }
}

enum DeviceScene {
    static var window: UIWindowScene? {
        var first: UIWindowScene?
        for scene in UIApplication.shared.connectedScenes {
            guard let window = scene as? UIWindowScene else { continue }
            if window.activationState == .foregroundActive { return window }
            if first == nil { first = window }
        }
        return first
    }

    /// Asked of the orientation the scene is moving to, the only signal a rotation gives mid-rotation. Layout geometry answers landscape for an upright phone with its keyboard up.
    static var isLandscape: Bool {
        window?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
    }

    /// The width the foldable's outer display reserves down its right edge for the camera hole and the clock. The inner display reserves none.
    static var trailingInset: CGFloat { window?.windows.first?.safeAreaInsets.right ?? 0 }

    static var bottomInset: CGFloat { window?.windows.first?.safeAreaInsets.bottom ?? 0 }

    /// Any phone screen that reserves a strip down its right edge (the foldable's), in either orientation, where the clock sits with room under it for a rail.
    /// The screen's shape is checked as well as the inset: any iPhone on its side reports about 59 points on the right for its sensor housing, and without the shape test every ordinary phone in landscape drew its rail in a strip that is not there.
    static var hasReservedStrip: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone, trailingInset >= 40, let bounds = window?.screen.bounds else { return false }
        return ScreenShape.isBookShaped(size: bounds.size)
    }

    /// The foldable's outer display held upright: near-square, with a strip reserved down its right edge, where a column of controls fits. Sideways it is nearly the Mac's own shape, and the unfolded inner display reserves no strip, so both keep the ordinary layouts. An iPad is near-square too, but has room for the ordinary layout.
    static var isBookShaped: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone, !isLandscape, trailingInset >= 40, let bounds = window?.screen.bounds else { return false }
        return ScreenShape.isBookShaped(size: bounds.size)
    }
}

extension View {
    func adaptiveContentColumn(maxWidth: CGFloat? = nil) -> some View {
        modifier(AdaptiveContentColumn(explicitMaxWidth: maxWidth))
    }
}

private struct AdaptiveContentColumn: ViewModifier {
    let explicitMaxWidth: CGFloat?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var maxWidth: CGFloat {
        explicitMaxWidth ?? (horizontalSizeClass == .regular
            ? AdaptiveLayout.wideContentMaxWidth
            : AdaptiveLayout.contentMaxWidth)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

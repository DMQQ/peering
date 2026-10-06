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

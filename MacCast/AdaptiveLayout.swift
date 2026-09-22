import SwiftUI
import UIKit

/// Shared layout decisions for screens that are readable columns rather than remote canvases.
///
/// A phone naturally supplies a useful line length. An iPad does not: letting settings, help, or
/// connection cards grow to the full display turns short rows into long horizontal scans. These
/// values keep the same visual rhythm while the outer container uses the space for navigation.
enum AdaptiveLayout {
    static let contentMaxWidth: CGFloat = 760

    static var deviceSymbol: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }
}

extension View {
    /// Centres a readable app column in whatever width its navigation container provides.
    func adaptiveContentColumn(maxWidth: CGFloat = AdaptiveLayout.contentMaxWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

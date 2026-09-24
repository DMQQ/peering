import SwiftUI
import UIKit

/// Shared layout decisions for screens that are readable columns rather than remote canvases.
///
/// A phone naturally supplies a useful line length. An iPad does not: letting settings, help, or
/// connection cards grow to the full display turns short rows into long horizontal scans. These
/// values keep the same visual rhythm while the outer container uses the space for navigation.
enum AdaptiveLayout {
    static let contentMaxWidth: CGFloat = 760

    /// The column's width in a regular-width layout: an iPad's detail pane beside
    /// `NavigationSplitView`'s sidebar, or an iPhone held sideways.
    ///
    /// `contentMaxWidth` was chosen against a phone's own width. Held to that same figure beside
    /// an iPad's sidebar, a card of dense rows — the Sessions tab's recent-connections list is the
    /// one this was felt on — read as a phone-width column that happened to be centred in a wider
    /// pane, with the gutters on both sides wider than the column itself.
    static let wideContentMaxWidth: CGFloat = 920

    static var deviceSymbol: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }
}

extension View {
    /// Centres a readable app column in whatever width its navigation container provides.
    ///
    /// Reads the horizontal size class itself rather than taking a fixed width, so the same call
    /// at every site widens together on an iPad instead of each screen guessing its own number.
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

import SwiftUI

extension View {
    /// Records the screen as viewed and as the one a rage click is attributed to while it is up.
    func analyticsScreen(_ screen: Analytics.Screen) -> some View {
        onAppear { Analytics.screenAppeared(screen) }
            .onDisappear { Analytics.screenDisappeared(screen) }
    }
}

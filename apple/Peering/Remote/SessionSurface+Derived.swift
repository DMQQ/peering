import PeeringKit
import RemoteCore
import SwiftUI

extension SessionSurface {
    /// 0 with the shortcut keys folded away and 1 with them shown, following the finger while the handle is dragged.
    var shortcutsProgress: CGFloat {
        let settled: CGFloat = shortcutsExpanded ? 1 : 0
        guard keyRowsHeight > 0 else { return settled }
        return min(1, max(0, settled - shortcutsDrag / keyRowsHeight))
    }
    var shortcutsCollapsed: Bool { shortcutsProgress < 0.5 }

    var showsTerminals: Bool {
        get { route.hubIsOpen }
        nonmutating set { route = newValue ? route.withHub(steps: route.steps) : route.base }
    }

    var dueScreenTours: [Tour] {
        guard model.phase == .ready, !showsLandscapeHint, !hasSeenTourScreen else { return [] }
        return [.screen]
    }
}

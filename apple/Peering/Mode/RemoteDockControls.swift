import RemoteCore
import SwiftUI

/// What the trackpad's dock row asks for. The row draws; the dock view acts.
struct RemoteDockControlActions {
    var onKeyboard: () -> Void
    var onDesktops: () -> Void
    var onApps: () -> Void
    var onShortcuts: () -> Void
    var onLock: () -> Void
    var onKey: (RemoteDockKey) -> Void
}

/// The trackpad's dock, drawn as the screen view's is: one glass bar of rail buttons, each an icon over its name. While the keyboard is up it holds the keys the iPhone keyboard lacks.
struct RemoteDockControls: View {
    let typing: Bool
    /// The Mac's desktop count and the current one (1-based), when it sent them.
    let desktops: (count: Int, current: Int?)?
    let actions: RemoteDockControlActions

    private static let barKeys: [RemoteDockKey] = [.escape, .tab, .left, .up, .down, .right]

    var body: some View {
        HStack(spacing: ChromeMetrics.buttonGap) {
            if typing {
                ForEach(Self.barKeys) { key in
                    RailButton(icon: key.symbol, label: key.shortName) { actions.onKey(key) }
                }
            } else {
                RailButton(icon: "keyboard", label: String(localized: "Keyboard"), action: actions.onKeyboard)
                desktopsButton
                RailButton(icon: "rectangle.on.rectangle", label: String(localized: "Apps"), action: actions.onApps)
                RailButton(icon: "command", label: String(localized: "Shortcuts"), action: actions.onShortcuts)
                RailButton(icon: "lock", label: String(localized: "Lock"), action: actions.onLock)
            }
        }
        .padding(.vertical, ChromeMetrics.railPadding)
        .padding(.horizontal, ChromeMetrics.railSidePadding)
        .frame(height: ChromeMetrics.dockCollapsedHeight)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.dockCollapsedRadius, style: .continuous))
        .animation(Motion.settle, value: typing)
    }

    private var desktopsButton: some View {
        RailButton(icon: "square.split.2x1", label: desktopTitle, action: actions.onDesktops)
    }

    private var desktopTitle: String {
        guard let current = desktops?.current else { return String(localized: "Desktops") }
        return String(localized: "Desktop \(current)")
    }
}

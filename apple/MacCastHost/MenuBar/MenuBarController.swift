import AppKit
import SwiftUI

/// The status item and its popover. An `NSPopover` is centred under the item and draws its own
/// arrow, which `MenuBarExtra`'s window style can do neither of.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(model: HostModel, updater: Updater) {
        super.init()
        configureButton(model: model)
        configurePopover(model: model, updater: updater)
    }

    private func configureButton(model: HostModel) {
        statusItem.autosaveName = "pl.dmq.peering.host.statusItem"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityLabel("Peering")

        let label = PassthroughHostingView(rootView: MenuBarStatusLabel().environment(model))
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        // The button has no intrinsic size of its own, so a variable length would collapse.
        statusItem.length = label.fittingSize.width + 8
    }

    private func configurePopover(model: HostModel, updater: Updater) {
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let content = HostMenuBarContent()
            .environment(model)
            .environment(updater)
            .environment(\.dismissMenuBar) { [weak self] in self?.popover.performClose(nil) }
            .preferredColorScheme(.dark)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button, button.window != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

/// Reads the state in its own body: an `@Observable` read there is what invalidates the label.
private struct MenuBarStatusLabel: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        HostMenuBarLabel(state: model.menuBarState)
    }
}

/// Lets clicks fall through to the status item's button underneath.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

/// Animated on the window: the system shows the panel at full opacity, so it is caught before the first frame.
struct PanelWindowEntrance: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?
        private var exitObserver: NSObjectProtocol?
        private var animating = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            animate(window)
            // The window is kept and reshown on every click, so each showing is its own entrance.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.animate(window) }
            }
            exitObserver.map(NotificationCenter.default.removeObserver)
            exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.animateExit(from: window) }
            }
        }

        /// The panel is ordered out the moment it resigns key, so the exit plays on a snapshot
        /// in a stand-in window at the same place.
        private func animateExit(from window: NSWindow) {
            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            let snapshot = NSImage(size: content.bounds.size)
            snapshot.addRepresentation(rep)

            let ghost = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            ghost.isReleasedWhenClosed = false
            ghost.backgroundColor = .clear
            ghost.isOpaque = false
            ghost.hasShadow = true
            ghost.level = window.level
            ghost.ignoresMouseEvents = true
            // The snapshot cannot capture the panel's blurred material, so the ghost draws its own.
            let image = NSVisualEffectView(frame: content.bounds)
            image.material = .menu
            image.state = .active
            image.blendingMode = .behindWindow
            image.wantsLayer = true
            image.layer?.cornerRadius = 16
            image.layer?.cornerCurve = .continuous
            image.layer?.masksToBounds = true
            let picture = NSImageView(image: snapshot)
            picture.frame = content.bounds
            picture.autoresizingMask = [.width, .height]
            image.addSubview(picture)
            ghost.contentView = image
            ghost.orderFront(nil)
            // The system fades the real panel out as well, which drew the card twice.
            window.alphaValue = 0

            if let layer = image.layer {
                let bounds = layer.bounds
                var to = CATransform3DMakeTranslation(bounds.midX, bounds.maxY, 0)
                to = CATransform3DScale(to, 0.75, 0.75, 1)
                to = CATransform3DTranslate(to, -bounds.midX, -bounds.maxY, 0)
                let zoom = CABasicAnimation(keyPath: "transform")
                zoom.fromValue = CATransform3DIdentity
                zoom.toValue = to
                zoom.duration = 0.2
                zoom.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
                zoom.fillMode = .forwards
                zoom.isRemovedOnCompletion = false
                layer.add(zoom, forKey: "exit")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                ghost.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { ghost.orderOut(nil) }
            }
        }

        private func animate(_ window: NSWindow) {
            // Both the first showing and becoming key arrive for the first click.
            guard !animating else { return }
            animating = true
            window.alphaValue = 0
            // Scaled about the top centre, so the panel grows out of the menu bar icon.
            window.contentView?.wantsLayer = true
            if let layer = window.contentView?.layer {
                let bounds = layer.bounds
                var from = CATransform3DMakeTranslation(bounds.midX, bounds.maxY, 0)
                from = CATransform3DScale(from, 0.75, 0.75, 1)
                from = CATransform3DTranslate(from, -bounds.midX, -bounds.maxY, 0)
                let zoom = CABasicAnimation(keyPath: "transform")
                zoom.fromValue = from
                zoom.toValue = CATransform3DIdentity
                zoom.duration = 0.32
                zoom.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
                layer.add(zoom, forKey: "entrance")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.animating = false }
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

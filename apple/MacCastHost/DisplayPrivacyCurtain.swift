import AppKit
import CoreGraphics
import SwiftUI

/// sharingType = .none keeps the cover out of captures made by other processes (the phone stream and screenshots).
/// Deliberately a hair translucent: the window server stops compositing a window nothing can see, so an opaque cover would drop every window it hides from the phone picture.
/// Configured and drawn before it is ordered front, or it flashes white on the panel.
/// Takes no mouse events: injected CGEvents use the same hit test, so an unclickable cover would block the phone clicks too.
@MainActor
final class DisplayPrivacyCurtain {
    struct Refusal {
        let display: LocalizedStringResource
        let reason: LocalizedStringResource
    }

    struct Report {
        var covered: [CGDirectDisplayID] = []
        var refused: [Refusal] = []
    }

    /// Called when a cover is taken back down: the window server answer only arrives after the call returns. See verify.
    var onUncovered: (([Refusal]) -> Void)?

    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    var isUp: Bool { !windows.isEmpty }

    @discardableResult
    func cover(_ displays: [CGDirectDisplayID]) -> Report {
        var report = Report()
        let wanted = Set(displays)

        for (displayID, window) in windows where !wanted.contains(displayID) {
            window.close()
            windows[displayID] = nil
        }

        var raised: [CGDirectDisplayID: String] = [:]
        for displayID in displays {
            guard let screen = Self.screen(for: displayID) else {
                takeDown(displayID)
                report.refused.append(Refusal(
                    display: "display \(displayID)",
                    reason: "the window server has no screen for it"
                ))
                continue
            }
            if let window = windows[displayID] {
                // Not animated: a resizing window is the same flash as one arriving unconfigured.
                if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
            } else {
                windows[displayID] = Self.makeWindow(on: screen)
                raised[displayID] = screen.localizedName
            }
            report.covered.append(displayID)
        }

        if !raised.isEmpty { verify(Array(raised.keys), names: raised) }
        return report
    }

    func lift() {
        for window in windows.values { window.close() }
        windows = [:]
    }

    private func takeDown(_ displayID: CGDirectDisplayID) {
        windows[displayID]?.close()
        windows[displayID] = nil
    }

    /// Run a moment later: the window is not yet in the server on-screen list, which would refuse every cover. A cover the server does not hide shows as a black rectangle in the phone stream; one it treats as a wall drops all windows. Either is taken down.
    private func verify(_ displayIDs: [CGDirectDisplayID], names: [CGDirectDisplayID: String]) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.verificationDelay)
            guard let self else { return }
            var uncovered: [Refusal] = []
            for displayID in displayIDs {
                guard let window = self.windows[displayID] else { continue }
                let name: LocalizedStringResource = names[displayID].map { "\($0)" } ?? "display \(displayID)"
                guard let state = Self.serverState(of: window.windowNumber) else {
                    self.takeDown(displayID)
                    uncovered.append(Refusal(display: name, reason: "the window server did not answer for it"))
                    continue
                }
                guard state.hiddenFromCapture else {
                    self.takeDown(displayID)
                    uncovered.append(Refusal(
                        display: name,
                        reason: "the window server would not keep it out of screen capture"
                    ))
                    continue
                }
                guard state.veiled else {
                    self.takeDown(displayID)
                    uncovered.append(Refusal(
                        display: name,
                        reason: "the window server treats it as opaque, which would hide this display's windows from the phone"
                    ))
                    continue
                }
            }
            guard !uncovered.isEmpty else { return }
            self.onUncovered?(uncovered)
        }
    }

    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        // Nothing to drag: no title bar, not movable, not moved by content drags.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        // Above the Dock and menu bar, below the lock screen so its password prompt still shows.
        window.level = .screenSaver
        // On every desktop and not carried away by space animations, or a swipe uncovers the screen.
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.ignoresMouseEvents = true
        window.sharingType = .none
        // The veil: opaque is wrong (see the type note), and 0.995 stays translucent even if alpha is rounded to eight bits.
        window.alphaValue = Self.veil
        window.contentView = NSHostingView(
            rootView: DisplayPrivacyCurtainMark(bounds: screen.frame.size)
        )
        window.displayIfNeeded()
        window.orderFrontRegardless()
        return window
    }

    private static func serverState(of windowNumber: Int) -> (hiddenFromCapture: Bool, veiled: Bool)? {
        guard let listed = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(windowNumber)
        ) as? [[String: Any]],
            let entry = listed.first,
            let sharing = entry[kCGWindowSharingState as String] as? NSNumber,
            let alpha = entry[kCGWindowAlpha as String] as? NSNumber
        else { return nil }
        return (
            hiddenFromCapture: sharing.intValue == Int(NSWindow.SharingType.none.rawValue),
            veiled: alpha.doubleValue < 1
        )
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }

    private static let verificationDelay: Duration = .milliseconds(80)

    private static let veil: CGFloat = 0.995
}

/// Without motion a still black screen looks like a Mac that has stopped. No wording, and nothing saying the screen is watched.
private struct DisplayPrivacyCurtainMark: View {
    let bounds: CGSize

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.periodic(from: .now, by: CurtainDrift.frameInterval)) { context in
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .position(CurtainDrift.position(at: context.date, in: bounds, size: size))
            }
        }
        .ignoresSafeArea()
    }

    private var size: CGFloat { CurtainDrift.size(for: bounds.height) }
}

/// A triangle wave per axis from the clock, not accumulated per frame, so dropped frames do not shift it. Kept out of the view so it is testable.
enum CurtainDrift {
    /// A share of display height, clamped at both ends.
    static func size(for displayHeight: CGFloat) -> CGFloat {
        min(max(displayHeight * 0.075, 44), 140)
    }

    static func position(at date: Date, in bounds: CGSize, size: CGFloat) -> CGPoint {
        let seconds = date.timeIntervalSinceReferenceDate
        let room = CGSize(width: max(bounds.width - size, 0), height: max(bounds.height - size, 0))
        return CGPoint(
            x: size / 2 + travel(seconds, crossing: crossing, distance: room.width),
            y: size / 2 + travel(seconds, crossing: crossing * crossingRatio, distance: room.height)
        )
    }

    static let crossing: TimeInterval = 55

    /// Not equal to the horizontal crossing: a fixed ratio retraces the same line.
    static let crossingRatio = 1.37

    static let frameInterval: TimeInterval = 1 / 30

    private static func travel(
        _ seconds: TimeInterval,
        crossing: TimeInterval,
        distance: CGFloat
    ) -> CGFloat {
        guard distance > 0 else { return 0 }
        let phase = (seconds / crossing).truncatingRemainder(dividingBy: 2)
        return distance * (phase <= 1 ? phase : 2 - phase)
    }
}

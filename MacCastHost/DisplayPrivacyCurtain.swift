import AppKit
import CoreGraphics
import SwiftUI

/// The cover Privacy Mode puts over every display whose brightness macOS will not set.
///
/// One borderless window per display at a level above every ordinary one, so the panel in front
/// of a person in the room goes black while the pixels behind it are exactly what they were and
/// the phone's picture of that display is untouched.
///
/// `sharingType = .none` is what keeps the cover out of that picture: the window server leaves a
/// window with that state out of a capture made by any other process, which is the path the
/// phone's stream takes (`SCContentFilter(display:excludingWindows:)` in
/// ``ScreenCaptureSourceResolver``, and ``SCScreenshotManager`` for the desktops and thumbnails).
///
/// A hair of translucency is the second half, and it is not decoration. The window server stops
/// compositing a window that nothing can see, so an opaque cover would take every window it hides
/// out of the picture with it: the phone would be sent a bare desktop, with the menu bar and the
/// wallpaper and no application in sight. A cover that is not quite opaque is not a wall, the
/// server keeps compositing what is behind it, and the phone sees the desktop it was watching. On
/// a screen this dark the veil costs about one level of grey where the desktop behind it is white,
/// which is not a picture anybody can read, and it is why the person sees black and the phone
/// does not.
///
/// The cover is configured, drawn and only then put on screen. A window ordered front before it
/// is black is a flash of white on the panel Privacy Mode exists to take attention away from.
///
/// It does not take mouse events, and that is a decision rather than an oversight. Taking them
/// would swallow the phone's own clicks with the person's: an injected `CGEvent` is routed by the
/// same hit test a real one is (`InputInjector`), so a cover the Mac cannot be clicked through is
/// a cover the phone cannot be clicked through either.
@MainActor
final class DisplayPrivacyCurtain {
    enum Failure: LocalizedError {
        case notHiddenFromCapture
        case hiddenFromThePhone

        var errorDescription: String? {
            switch self {
            case .notHiddenFromCapture:
                return "the window server would not keep it out of screen capture"
            case .hiddenFromThePhone:
                return "the window server treats it as opaque, which would hide this display's windows from the phone"
            }
        }
    }

    /// A display left uncovered, and why. The name is the one the person at the Mac would use.
    struct Refusal {
        let display: String
        let reason: String
    }

    struct Report {
        var covered: [CGDirectDisplayID] = []
        var refused: [Refusal] = []
    }

    /// Told about a cover that had to be taken back down, which is the one failure this type
    /// cannot report to its caller directly: the window server's answer only arrives after the
    /// call that put the cover up has returned. See ``verify(_:names:)``.
    var onUncovered: (([Refusal]) -> Void)?

    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    var isUp: Bool { !windows.isEmpty }

    /// Covers exactly `displays`, and takes down the cover of any display not in the list.
    ///
    /// Safe to call again with a fresh list, which is what a display arriving or leaving during a
    /// session does. Returns once the covers are up, which is not the same moment as knowing they
    /// are right: see ``verify(_:names:)``.
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
                // A display can change shape under a cover that is already up. Not animated:
                // a window resizing on screen is the same flash as one arriving unconfigured.
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

    /// Checks its own work once the window server has caught up, and takes down any cover that is
    /// not both invisible to capture and see-through.
    ///
    /// The question cannot be asked in the same turn the window was ordered in: the window is
    /// not in the server's on-screen list yet, so the honest answer there is "not there", which
    /// would refuse every cover ever made. Asked a moment later it is the real state, and both
    /// answers matter: a cover the server does not hide is a black rectangle in the phone's
    /// stream, the worst failure this app has and one that looks exactly like a denied Screen
    /// Recording permission, and a cover it takes for a wall is a phone picture with no windows
    /// in it. Either way the cover comes back down and the caller is told: a display this Mac
    /// cannot cover is one Privacy Mode leaves alone.
    private func verify(_ displayIDs: [CGDirectDisplayID], names: [CGDirectDisplayID: String]) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.verificationDelay)
            guard let self else { return }
            var uncovered: [Refusal] = []
            for displayID in displayIDs {
                // Gone already means the cover was lifted while this was waiting, which is not a
                // failure and not this pass's business.
                guard let window = self.windows[displayID] else { continue }
                let name = names[displayID] ?? "display \(displayID)"
                guard let state = Self.serverState(of: window.windowNumber) else {
                    self.takeDown(displayID)
                    uncovered.append(Refusal(display: name, reason: "the window server did not answer for it"))
                    continue
                }
                guard state.hiddenFromCapture else {
                    self.takeDown(displayID)
                    uncovered.append(Refusal(
                        display: name,
                        reason: Failure.notHiddenFromCapture.errorDescription ?? "it could not be hidden from screen capture"
                    ))
                    continue
                }
                guard state.veiled else {
                    self.takeDown(displayID)
                    uncovered.append(Refusal(
                        display: name,
                        reason: Failure.hiddenFromThePhone.errorDescription ?? "it would hide this display's windows from the phone"
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
        // Nothing to drag and nothing to grab: the window has no title bar, is not movable, and
        // does not move when its own content is dragged. What covers the screen cannot be pushed
        // aside to look under it.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        // Above the Dock, the menu bar and every ordinary window; below the lock screen, so a Mac
        // locked with a cover up still shows its own password prompt.
        window.level = .screenSaver
        // On every desktop the display has, and not carried away by the animation between them:
        // a cover that left with the desktop it was put on uncovers the screen on the first swipe.
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.ignoresMouseEvents = true
        window.sharingType = .none
        // The veil, and the one number in this file that is load-bearing rather than a matter of
        // taste. Opaque is the obvious answer and it is the wrong one: see the type's note on what
        // the window server does with the windows an opaque cover hides. A half a per cent of the
        // desktop comes through, which on this black is under two levels of grey where the desktop
        // behind it is pure white, and which is far enough from 1.0 that an implementation that
        // rounded alpha to eight bits would still leave it translucent.
        window.alphaValue = Self.veil
        window.contentView = NSHostingView(
            rootView: DisplayPrivacyCurtainMark(bounds: screen.frame.size)
        )
        // Draws the black and the mark into the surface before any of it is on screen, so the
        // first frame the panel shows is the finished cover rather than an empty one.
        window.displayIfNeeded()
        window.orderFrontRegardless()
        return window
    }

    /// What the window server says about a cover: the two properties this whole type depends on.
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

    /// Long enough that a window ordered in this turn is in the window server's on-screen list
    /// and its state can be read back. Short enough that a cover which never appears in the
    /// phone's picture is not something a person has to sit through.
    private static let verificationDelay: Duration = .milliseconds(80)

    /// See the note where the window takes it.
    private static let veil: CGFloat = 0.995
}

/// The app's mark, drifting across the cover.
///
/// A screen that is completely still is indistinguishable from a Mac that has stopped, which is
/// the one thought somebody sitting in front of a black screen should not have to have. It is the
/// app's own icon, drawn as the Dock draws it, and nothing else: no wording at all, and above all
/// nothing that says a screen is being watched, which would defeat the case Privacy Mode exists
/// for.
private struct DisplayPrivacyCurtainMark: View {
    let bounds: CGSize

    var body: some View {
        ZStack {
            // Pure black rather than the stage's near-black: this is not a surface anything sits
            // on, it is the absence of the picture, and it is what the window behind it is too.
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

/// Where the mark is, and how fast it moves.
///
/// A triangle wave per axis, computed from the clock rather than accumulated frame by frame: the
/// mark is exactly at the edge when it turns around, however many frames were drawn to get it
/// there, and a dropped frame moves it no further along than it would have been. Kept out of the
/// view it draws so the movement can be checked without a window on screen.
enum CurtainDrift {
    /// The mark's size on a display of this height, in points, which is what the layout wants.
    ///
    /// A share of the display rather than a number, so it reads the same on a laptop panel and on
    /// a 4K monitor. Clamped at both ends: below the floor there is nothing left of the drawing,
    /// and above the ceiling it stops being a mark and becomes a picture of itself.
    static func size(for displayHeight: CGFloat) -> CGFloat {
        min(max(displayHeight * 0.075, 44), 140)
    }

    /// Where the mark sits at this instant, in the display's own points.
    static func position(at date: Date, in bounds: CGSize, size: CGFloat) -> CGPoint {
        let seconds = date.timeIntervalSinceReferenceDate
        let room = CGSize(width: max(bounds.width - size, 0), height: max(bounds.height - size, 0))
        return CGPoint(
            x: size / 2 + travel(seconds, crossing: crossing, distance: room.width),
            y: size / 2 + travel(seconds, crossing: crossing * crossingRatio, distance: room.height)
        )
    }

    /// Seconds to cross the display once. Slow enough to be a drift rather than an animation, and
    /// so the mark is something to notice once rather than to watch.
    static let crossing: TimeInterval = 55

    /// The vertical crossing is deliberately not the horizontal one. Two axes in a fixed ratio
    /// retrace the same line across the screen, and this is meant to be looked past.
    static let crossingRatio = 1.37

    /// The drift is a slow linear movement, so it needs no more frames than this; a display's own
    /// refresh rate would be spent on a mark that moves about a point per frame.
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

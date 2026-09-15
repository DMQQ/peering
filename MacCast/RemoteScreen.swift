import RemoteCore
import SwiftUI
import UIKit

/// The pointer's radius.
///
/// A file-level constant because three numbers have to agree: the circle's size, the horizontal
/// offset that centres it on the rail above it, and the centring of the key stacked on top of it.
private let joystickRadius: CGFloat = 50

/// The remote desktop itself: picture, pointer, keyboard, and the controls for all three.
struct RemoteScreen: View {
    @Environment(SessionModel.self) private var model

    /// Persisted, because a user who works in drag & zoom on a phone should not have to say so
    /// again on every launch.
    @AppStorage("Peering.interactionMode") private var interactionMode: InteractionMode = .control

    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted because it is a property of the *source*, not of the moment: a window captured
    /// on its own is usually a different shape from the screen, and someone who has just filled
    /// it will want the next one filled too.
    @AppStorage("Peering.scalesToFill") private var scalesToFill = false

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    /// Whether picking something from a floating panel puts the panel away.
    ///
    /// Persisted, because it is a working style rather than a moment: someone moving between a
    /// Mac's desktops wants the panel out of the way after each one, and someone picking their way
    /// through several sources in a row wants it to stay put.
    @AppStorage(PreferenceKey.hidesPanelAfterSelect) private var hidesPanelAfterSelect = true

    /// The turn-your-phone card, and the timer that takes it away again — see
    /// ``presentLandscapeHint()``.
    ///
    /// No "has it been shown" flag is needed. `ContentView` swaps this whole view out whenever the
    /// phase leaves the remote screens, so the state below is built fresh at the start of every
    /// session and cannot survive into the next one.
    @State private var showsLandscapeHint = false
    @State private var landscapeHintTask: Task<Void, Never>?
    /// Set when iOS refused a rotation, which means Rotation Lock is on. Lasts as long as the
    /// session does, because the condition it describes does too.
    @State private var rotationRefused = false

    @State private var openPanel: Panel?
    @State private var statusBarExpanded = true
    /// Whether the portrait dock has opened onto the controls that did not earn a permanent
    /// place in it. Portrait's alone — the landscape rails have the height to show them all.
    @State private var dockExpanded = false
    /// The pending auto-collapse, so expanding by hand can cancel the one already in flight.
    @State private var statusBarCollapseTask: Task<Void, Never>?

    /// Where the window's own controls are, in the canvas's coordinates.
    ///
    /// The gesture surface has to be told: it is a UIKit view under SwiftUI's drawing, so a
    /// touch aimed at a button still reaches it, and a thumb that slides while pressing starts a
    /// drag on the Mac underneath — moving its pointer to wherever the finger happened to be.
    @State private var chromeFrames: [ChromeRegion: CGRect] = [:]

    private let minimumZoom: CGFloat = 0.5
    private let maximumZoom: CGFloat = 8

    /// The one sliding panel.
    ///
    /// An enum rather than a boolean per panel, so "only one at a time" is true by construction.
    /// Two booleans could both be set, and the screen then had no rule about which of them won —
    /// which is how the two panels ended up overlapping in the first place.
    private enum Panel {
        case shortcuts
        case desktops
        case sources
        case settings
    }

    /// Shows the turn-your-phone card, once, to a session that came up in portrait.
    ///
    /// Portrait is not a failure — the dock and the joystick are built for it — but a Mac's
    /// screen is wide, and side-on is where the picture gets the whole display. Most people work
    /// that out on their own within a few seconds; the card spends three of them saying so and
    /// then gets out of the way, which is why it is timed rather than something to dismiss.
    private func presentLandscapeHint() {
        guard !deviceIsLandscape, !showsLandscapeHint else { return }
        withAnimation(Motion.settle) { showsLandscapeHint = true }

        landscapeHintTask?.cancel()
        landscapeHintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            dismissLandscapeHint()
        }
    }

    private func dismissLandscapeHint() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil
        withAnimation(Motion.settle) { showsLandscapeHint = false }
    }

    /// Asks iOS to turn the phone, which is the only help available to a user whose Rotation Lock
    /// is on.
    ///
    /// An app cannot read Rotation Lock. It can only ask, and the ask either happens or comes back
    /// as an error — so the error handler is the only way to tell a locked phone from a working
    /// one, and it is what turns this card into the instructions for unlocking it.
    ///
    /// The card stops fading while the request is out. A button that dismisses the thing it sits
    /// on halfway through being pressed is worse than no button at all.
    private func rotateToLandscape() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
            // The handler is not guaranteed to be on the main actor and it writes view state, so
            // it comes back to it first.
            Task { @MainActor in
                withAnimation(Motion.settle) { rotationRefused = true }
            }
        }
    }

    /// Whether the phone is held sideways.
    ///
    /// Asked of the window rather than of the geometry the chrome is laid out in, and a bug lives
    /// in that difference. Two things inset that geometry from the bottom: the software keyboard,
    /// and the input bar added above it. On a phone held upright with the keyboard up, what was
    /// left was shorter than it was wide — so `width > height`, which is the test that decides
    /// *which* set of controls to draw, answered *landscape*, and the rails came down the edges of
    /// a portrait screen behind a keyboard and went away again when it was dismissed.
    ///
    /// The geometry cannot be asked instead: a `safeAreaInset` shrinks its content by design, and
    /// it has to, because the bar belongs above the keyboard. Which is why this one question is
    /// the one thing asked somewhere the keyboard cannot reach. The chrome is still *laid out* in
    /// the geometry, because it does have to stay clear of the keyboard.
    private var deviceIsLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation
            .isLandscape ?? false
    }

    var body: some View {
        // `Environment` gives the object but no projected value, so a local `@Bindable` is
        // what turns `model.showKeyboard` into something the keyboard view can bind to.
        @Bindable var model = model
        return GeometryReader { proxy in
            let isLandscape = deviceIsLandscape
            ZStack {
                // Black here, where every other screen in the app uses the near-black backdrop
                // — and the difference is the picture. The video is letterboxed on any screen
                // that is not the Mac's own shape, and those bars sit directly against whatever
                // the Mac itself is showing in black: its desktop's letterbox, a dark editor, a
                // terminal. At 0.04 the join is a visible edge around the picture, which reads
                // as the picture being inset in a panel rather than as being the screen. At
                // zero the bars and the video's own black are the same black and the only thing
                // on screen is the Mac.
                Color.black.ignoresSafeArea()

                video
                gestures
                sessionChrome(isLandscape: isLandscape, available: proxy.size)

                if case .confirming(let code) = model.phase {
                    PairingPrompt(code: code, hostName: model.hostName ?? "this Mac")
                }

                if model.phase == .connecting || model.phase == .handshaking {
                    ProgressOverlay(
                        title: model.phase == .connecting ? "Connecting…" : "Securing the connection…",
                        detail: model.hostName
                    )
                }

                // Hidden the moment the phone is actually turned, which is the whole of what it
                // asks for. The timer is still running underneath and will find it already gone.
                if showsLandscapeHint, !isLandscape {
                    LandscapeHint(
                        rotationRefused: rotationRefused,
                        onRotate: rotateToLandscape,
                        onDismiss: dismissLandscapeHint
                    )
                    .transition(.opacity)
                }
            }
        }
        // The keyboard must not resize the picture. A remote desktop whose view shrinks every
        // time the system keyboard appears would move every control the user is aiming at.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.showKeyboard {
                keyboardInputBar
            }
        }
        .background {
            KeyboardCapture(model: model, isFocused: $model.showKeyboard)
                .frame(width: 0, height: 0)
        }
        // Nothing here is a sheet any more. Both of these are panels now, so the whole session —
        // what to share, what the connection is doing, the keys — lives in one visual language on
        // one layer, rather than three of them arriving from the bottom of the screen.
        // A hidden panel reports nothing, so its last frame would go on blocking touches in a
        // region that no longer has anything in it.
        // Keyed to the phase rather than to appearing, because a session does not arrive ready:
        // the screen is up during `.confirming` and the picture only starts at `.ready`, which is
        // the moment worth interrupting.
        .onChange(of: model.phase, initial: true) { _, phase in
            guard phase == .ready else { return }
            presentLandscapeHint()
        }
        .onChange(of: openPanel) { _, panel in
            if panel == nil { chromeFrames[.panel] = nil }

            // The desktop pictures are the one thing here that is stale by design — they are
            // photographs, not a stream, and the host re-takes them on a schedule of its own.
            // Opening the panel is the moment they are about to be looked at, so it is the
            // moment to ask. The answer does not come back through this call: the host pushes
            // a catalogue when a picture lands, the same way it does for any other change.
            if panel == .desktops { model.send(.refreshSpacePreviews) }
        }
    }

    // MARK: - Picture

    private var video: some View {
        VideoLayerView(renderer: model.renderer)
            .scaleEffect(effectiveZoom, anchor: .center)
            .offset(pan)
            .ignoresSafeArea()
            .overlay {
                // When the capture stream has stopped (source closed, app quit) the last
                // decoded frame stays visible on screen. Without a visual warning the user
                // touches what looks live but is actually stale — clicks land on whatever the
                // Mac currently shows at that position, not what the iPhone is displaying.
                if !model.isVideoStreaming && model.phase == .ready {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 8) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("Stream paused")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(model.videoStatus)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                    .allowsHitTesting(false)
                }

                // The Mac's own caption for a picture that is technically fine. Preferred to
                // the panel above, which never fires for this: a sleeping screen *is*
                // streaming — on time, at full rate, and entirely black — so "stream paused"
                // would be the wrong explanation and there would be no explanation at all.
                if let notice = model.remoteNotice, let message = notice.message, model.phase == .ready {
                    ZStack {
                        Color.black.opacity(0.72).ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: notice.symbol ?? "display.slash")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(message)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    }
                    // Hits pass through to the Mac, deliberately: an injected event is real
                    // user activity, and real user activity is what a sleeping display is
                    // waiting for. The way out of this screen is a tap on it.
                    .allowsHitTesting(false)
                }
            }
    }

    /// How much the picture has to grow to reach the screen's edges.
    ///
    /// A captured window is usually a different shape from a phone held sideways, so the fitted
    /// picture is a band with bars either side of it. This is the scale at which the *shorter*
    /// axis of the picture matches the screen — which fills it, and crops the other axis, which
    /// is what the user then pans around in drag & zoom.
    private var fillZoom: CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        let rect = CanvasGeometry.videoRect(bounds: canvasSize, pixelSize: model.capturePixelSize)
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return max(canvasSize.width / rect.width, canvasSize.height / rect.height)
    }

    /// What the picture is drawn at, and — because every touch is mapped back through it — what
    /// a touch means. One property rather than two, so a click can never be resolved against a
    /// scale the picture is not actually drawn at.
    private var effectiveZoom: CGFloat {
        scalesToFill ? max(zoom, fillZoom) : zoom
    }

    // MARK: - Gestures

    private var gestures: some View {
        CanvasGestureView(
            onTouchDown: { point in
                guard let normalized = normalized(point) else { return }
                // Down *before* the move would be wrong: the host injects a press at the
                // position of the last move it saw, so the order is move-then-press and the
                // coalescer is what guarantees the move gets out first.
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .left))
            },
            onTouchMove: { point in
                guard let normalized = normalized(point) else { return }
                model.send(.mouseMove(to: normalized))
            },
            onTouchUp: { point in
                guard let normalized = normalized(point) else { return }
                model.send(.mouseMove(to: normalized))
                model.send(.mouseUp(button: .left))
            },
            onSecondaryClick: { point in
                guard let normalized = normalized(point) else { return }
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .right))
                model.send(.mouseUp(button: .right))
            },
            onScroll: { translation in
                // Doubled into pixels, which is the unit the host's wheel event is built in
                // (`units: .pixel`). A point of finger travel moving one pixel would make
                // scrolling a page take several swipes.
                model.send(.scroll(dx: Double(translation.width) * 2, dy: Double(translation.height) * 2))
            },
            onZoom: { factor, _ in
                zoom = min(max(zoom * factor, minimumZoom), maximumZoom)
                // Zooming no longer decides what the fingers mean. It used to flip two-finger
                // drags between scrolling the Mac and moving the picture, so the same gesture
                // did different things depending on what the user had done minutes earlier.
                // Only the mode switch moves that, and only the user moves the mode switch.
                //
                // The pan is re-clamped rather than dropped past some threshold. Zooming out
                // shrinks what there is to pan over, and letting the offset stand until the
                // picture no longer overflows and then zeroing it snapped the view sideways in
                // one frame. Clamped every step, the picture slides back as the room for it goes.
                pan = clampedPan(pan)
            },
            onPanCanvas: { translation in
                pan = clampedPan(
                    CGSize(width: pan.width + translation.width,
                           height: pan.height + translation.height)
                )
            },
            onSizeChange: { canvasSize = $0 },
            interactionMode: interactionMode,
            // The drawn scale, not the user's zoom alone: `scalesToFill` enlarges the picture
            // without `zoom` moving, and a cropped picture is exactly the one with somewhere to
            // pan to. A hundredth of slack, so a floating-point return to 1.0 still counts as
            // fitted and gives the two-finger drag back to the Mac.
            isZoomed: effectiveZoom > 1.01,
            blockedRegions: blockedRegions,
            isPanelOpen: openPanel != nil,
            onDismissPanel: { withAnimation(Motion.settle) { openPanel = nil } },
            isStatusBarExpanded: statusBarExpanded,
            onCollapseStatusBar: { collapseStatusBar() },
            isKeyboardOpen: model.showKeyboard,
            onDismissKeyboard: { model.showKeyboard = false }
        )
        .ignoresSafeArea()
    }

    /// The regions a touch must not reach the Mac through.
    private var blockedRegions: [CGRect] {
        var regions = Array(chromeFrames.values)
        // A modal owns the whole screen while it is up. A tap meant for the pairing prompt must
        // not also land wherever the Mac's cursor happens to be sitting behind it.
        switch model.phase {
        case .connecting, .handshaking, .confirming:
            regions.append(CGRect(origin: .zero, size: canvasSize))
        default:
            break
        }
        return regions
    }

    /// How far the picture can move before one of its edges would leave the canvas.
    ///
    /// Drag & zoom makes this reachable: without a limit the picture can be flung off the screen
    /// altogether, and the only thing that brings it back is the zoom reset, which is hidden
    /// while the zoom is at 100%. Losing the Mac with no visible way back is not a mode anyone
    /// would keep using.
    /// How far past the edge the picture may be dragged.
    ///
    /// The clamp used to stop exactly where the picture's edge met the screen's, which sounds
    /// right and is not: at that limit a corner of the desktop sits in the screen's own corner —
    /// underneath the rail, and in landscape underneath the notch as well. The corner the user is
    /// dragging towards to *look at* is the one thing they cannot see.
    ///
    /// How far past the edge the picture may be dragged: the thickness of the chrome, measured
    /// from where it actually is.
    ///
    /// Measured rather than calculated, and that is the whole point. Both earlier attempts worked
    /// the number out from the rail's nominal width — once as the width itself, once as the width
    /// plus its edge inset — and both were short by the same thing neither knew about: the rails
    /// sit *inside the safe area*, which in landscape is a wide inset on the side the sensor
    /// housing is on. On this phone the rail's inner edge is 121 points from the screen's edge,
    /// not the 62 the metrics describe, so a corner dragged towards it came to rest underneath it
    /// either way. Reading the frames the chrome reports cannot be wrong about this.
    ///
    /// The larger of the two sides on each axis, because the clamp is symmetric. Taking the
    /// larger rather than averaging costs a little slack on the narrower side and buys a picture
    /// that behaves the same whichever way it is pushed.
    ///
    /// Only ever added to an axis that already overflows: with the picture fitted there is nothing
    /// to reveal, and a margin there would let a drag pull the picture away from its own edges and
    /// show the backdrop.
    private var panMargin: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        var leading: CGFloat = 0, trailing: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        for (region, rect) in chromeFrames where region != .panel {
            leading = max(leading, rect.minX)
            trailing = max(trailing, canvasSize.width - rect.maxX)
            top = max(top, rect.minY)
            bottom = max(bottom, canvasSize.height - rect.maxY)
        }
        // Plus a gap, so the picture's edge comes to rest beside the chrome rather than touching
        // it — the point is to see the edge, and an edge flush against a button is still an edge
        // that is hard to make out.
        let gap = ChromeMetrics.edgeInset * 2
        return CGSize(
            width: max(leading, trailing) + gap,
            height: max(top, bottom) + gap
        )
    }

    private var panLimit: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let rect = CanvasGeometry.videoRect(bounds: canvasSize, pixelSize: model.capturePixelSize)

        let margin = panMargin
        func limit(_ extent: CGFloat, _ canvas: CGFloat, _ margin: CGFloat) -> CGFloat {
            let slack = (extent * effectiveZoom - canvas) / 2
            return slack > 0 ? slack + margin : 0
        }
        return CGSize(
            width: limit(rect.width, canvasSize.width, margin.width),
            height: limit(rect.height, canvasSize.height, margin.height)
        )
    }

    private func clampedPan(_ proposed: CGSize) -> CGSize {
        let limit = panLimit
        return CGSize(
            width: min(max(proposed.width, -limit.width), limit.width),
            height: min(max(proposed.height, -limit.height), limit.height)
        )
    }

    private func normalized(_ point: CGPoint) -> NormalizedPoint? {
        CanvasGeometry.normalized(
            point: point,
            bounds: canvasSize,
            pixelSize: model.capturePixelSize,
            zoom: effectiveZoom,
            pan: pan
        )
    }

    // MARK: - Status

    /// The pill's outline, in whichever state it is in.
    ///
    /// A `RoundedRectangle` rather than the `Capsule` this was, and it is the corner radius that
    /// carries the animation: both the shape and the clip read from this one property, so the
    /// glass and the content it holds can never disagree about where the edge is — which is what
    /// a capsule's half-the-height corner was doing to the third row of the expanded panel.
    /// `continuous` because that is the curve iOS draws its own chrome with, and a circular
    /// corner beside it looks like a rectangle with the corners rounded off.
    private var pillShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: statusBarExpanded
                ? ChromeMetrics.pillExpandedRadius
                : ChromeMetrics.pillCollapsedRadius,
            style: .continuous
        )
    }

    /// What the pill holds, arriving and leaving.
    ///
    /// Delayed on the way in, so the contents land into a shape that has already started to open
    /// rather than travelling with its frame. That lag is the half of the effect the frame cannot
    /// do by itself: content that arrives with the frame reads as a panel switched on inside a box
    /// that happens to be resizing, and content that lands into a frame already in motion reads as
    /// one object changing shape.
    ///
    /// Leaving is not animated at all, and that is not a shortcut. A view being removed stays in
    /// its parent's layout for as long as its removal transition runs — so while the expanded
    /// panel faded out, the stack it is in would still be measuring it, and the pill would sit at
    /// its *open* size for the length of that fade before starting to close. Gone in one frame,
    /// the stack is the collapsed size on the next, and the spring has the whole of the travel to
    /// animate. What covers the disappearance is the clip: the shape closes over the content it
    /// is letting go of.
    private static let pillContents = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
        removal: .identity
    )

    private var statusBar: some View {
        // A `ZStack`, and this is the whole of why the pill grows rather than being replaced.
        //
        // It was a `Group`, and a `Group` is transparent: every modifier on one is applied to
        // each of its children instead of to a container around them. So the glass, the clip and
        // the corner were not one shape being asked to change size — they were a shape *per
        // state*, and flipping the branch threw one away and built the other. There was nothing
        // whose frame could be animated, so the old pill faded out and a larger one faded in,
        // which is exactly what it looked like.
        //
        // A container has an identity that survives the change, and a frame is a thing with an
        // identity that can be interpolated. Top-aligned because the two states are briefly both
        // present, and the pill should only ever grow downwards.
        ZStack(alignment: .top) {
            if statusBarExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // ── Row 1: identity + clock + quit ──────────────────────────────
                    HStack(spacing: 10) {
                        // Green once the session is up rather than merely connected: a socket
                        // that is open but still handshaking is not something to reassure
                        // anyone about, and the phase is the only thing that knows the
                        // difference.
                        Circle()
                            .fill(model.phase == .ready ? Color.green : ColorPalette.ink)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.hostName ?? "Mac")
                                .font(.subheadline.weight(.semibold))
                            Text(model.videoStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        sessionClock
                        if let latency = model.latencyMilliseconds {
                            Text("\(Int(latency.rounded())) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ColorPalette.reading(latency))
                        }
                        // The session's only way out, always visible in the expanded pill.
                        Button { model.disconnect() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("QUIT")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.9))
                        .accessibilityLabel("Quit session")
                    }

                    // ── Row 2: quality + view options ────────────────────────────────
                    HStack(spacing: 8) {
                        connectionPathChip
                        qualityPicker
                        fillChip
                        // iOS floats the picture on its own when the app goes away. This is
                        // for trying it *without* leaving, and for the log line that says why
                        // it refused — a start by hand is the same call the automatic one
                        // makes.
                        Button { SessionPiP.shared.start() } label: {
                            Image(systemName: "pip")
                                .font(.system(size: 13))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!SessionPiP.isSupported)
                        .accessibilityLabel("Float the picture over other apps")
                        if zoom > 1.01 {
                            Button {
                                zoom = 1; pan = .zero
                            } label: {
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.ultraThinMaterial).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }

                    // Its own row, and unbounded in both directions. What this carries is an
                    // error string from AVKit, and a *truncated* one is worth almost nothing —
                    // "Could not start: Failed to start pictu…" names neither the fault nor the
                    // reason. Set apart from the row above because it is a diagnostic, not a
                    // control: it takes whatever width it needs and wraps to whatever height.
                    if let attempt = SessionPiP.shared.lastAttempt {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pic-in-pic: \(attempt)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let why = SessionPiP.shared.lastRefusal {
                                Text(why)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                // The other half of the toggle. The collapsed bar expands on a tap and the
                // expanded one closes on the next, so it is one control with one meaning
                // rather than a button that only ever goes one way.
                .onTapGesture { collapseStatusBar() }
                // Opacity only, and on its own clock — see ``pillContents``. The scale that was
                // here made the two states cross-fade as though they were unrelated, one
                // shrinking away while the other grew in; what they are is the two faces of one
                // shape, so the shape carries the movement and the contents just appear in it.
                .transition(Self.pillContents)
            } else {
                HStack(spacing: 8) {
                    // Green when the Mac is connected and sending, red when it is connected and
                    // has stopped. It was white, which said nothing: a dot that is always the
                    // same colour is decoration, and this one sits in the pill that already
                    // carries the Mac's name and the latency — the two facts whose whole purpose
                    // is to be read at a glance.
                    //
                    // Green rather than the palette's white because the host picker already
                    // spends green on "this Mac is reachable", and a second colour for the same
                    // fact would be two vocabularies for one thing.
                    Circle()
                        .fill(model.isVideoStreaming ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(model.hostName ?? "Mac")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    connectionPathChip
                    if model.sessionStartedAt != nil {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        sessionClock
                    }
                    if let latency = model.latencyMilliseconds {
                        Text("\(Int(latency.rounded())) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ColorPalette.reading(latency))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .onTapGesture { expandStatusBar() }
                .contentShape(pillShape)
                // Opacity only, and on its own clock — see ``pillContents``. The scale that was
                // here made the two states cross-fade as though they were unrelated, one
                // shrinking away while the other grew in; what they are is the two faces of one
                // shape, so the shape carries the movement and the contents just appear in it.
                .transition(Self.pillContents)
            }
        }
        // Clipped to the shape, not to the rectangle it is drawn in. `.clipped()` cut the
        // contents off at the corners of the *bounds*, which left them showing outside the
        // rounded edge and over the picture behind — and the fix is not a smaller corner, it is
        // clipping to the same outline the glass is drawn in.
        //
        // It also carries the mid-flight case: the pill's content is laid out at its final size
        // from the first frame of the spring, so without this the expanded panel hangs below a
        // background that has not caught up to it yet.
        .clipShape(pillShape)
        .glassEffect(.regular, in: pillShape)
        .padding(.horizontal, 10)
        // The same inset as the rails, so the pill and the panels hang from one line.
        .padding(.top, ChromeMetrics.edgeInset)
        .reportChromeFrame(.statusBar, into: $chromeFrames)
        .task(id: model.phase) {
            // Expand a moment when the session comes up, then collapse — through the same
            // function a tap uses, so there is one place that knows about the pending timer.
            guard model.phase == .ready else { return }
            expandStatusBar()
        }
    }

    private var connectionPathChip: some View {
        Text(model.connectionPath?.rawValue ?? "None")
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.08), in: Capsule())
            .accessibilityLabel("Connection path")
    }

    private var qualityPicker: some View {
        HStack(spacing: 2) {
            ForEach(SessionModel.StreamQuality.allCases, id: \.self) { (preset: SessionModel.StreamQuality) in
                let selected = model.streamQuality == preset
                Button {
                    model.setStreamQuality(preset)
                } label: {
                    Text(preset.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? ColorPalette.ink : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            selected ? AnyShapeStyle(.primary.opacity(0.15)) : AnyShapeStyle(Color.clear),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
        .accessibilityLabel("Stream quality")
    }

    /// How long the session has been up.
    ///
    /// `Text(_:style:.timer)` is a clock the render server owns rather than a view that redraws:
    /// it advances on its own, costs nothing per second, and stays correct while the app is
    /// suspended. A `Timer` here would be a wake-up a second, for a label.
    ///
    /// Absent rather than zero before a session exists — "0:00" against a Mac that is not
    /// connected would be measuring nothing at all.
    @ViewBuilder
    private var sessionClock: some View {
        if let started = model.sessionStartedAt {
            Text(started, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Fitted or filled, named for the state it is in — like the mode button, and for the same
    /// reason: a control that advertises where it would go, while sitting in a state the user
    /// cannot read, is one whose meaning has to be remembered rather than seen.
    private var fillChip: some View {
        Button {
            withAnimation(Motion.settle) {
                scalesToFill.toggle()
                // The pan belongs to the old scale: a picture that was panned to the edge of a
                // fitted frame is off-screen the moment it grows to fill.
                pan = .zero
            }
        } label: {
            Text(scalesToFill ? "Fill" : "Fit")
                .font(.caption.monospacedDigit())
                .foregroundStyle(scalesToFill ? ColorPalette.ink : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(scalesToFill ? ColorPalette.selectedFill : .clear, in: Capsule())
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .accessibilityLabel(scalesToFill ? "Filling the screen" : "Fitted to the screen")
    }

    private func expandStatusBar() {
        withAnimation(Motion.morph) {
            statusBarExpanded = true
        }
        // Held, so a manual collapse cancels the timer rather than racing it: without this the
        // pending collapse fires anyway a moment later, and a deliberate expand that is closed
        // by hand would spring shut again on its own.
        statusBarCollapseTask?.cancel()
        statusBarCollapseTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            collapseStatusBar()
        }
    }

    private func collapseStatusBar() {
        statusBarCollapseTask?.cancel()
        statusBarCollapseTask = nil
        withAnimation(Motion.morph) {
            statusBarExpanded = false
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func sessionChrome(isLandscape: Bool, available: CGSize) -> some View {
        if isLandscape {
            ZStack(alignment: .top) {
                // Pinned to the top rather than centred. The rails grew a button each, and a
                // centred rail reaches far enough down that the pointer pad — which lives in
                // the bottom corner the thumb rests on — would land on top of the bottom
                // button and swallow its taps.
                //
                // Inside the safe area, deliberately. iOS reports *symmetric* landscape insets
                // whether or not the sensor housing is actually on that side, so the two edges
                // cannot be treated differently without guessing; content that ignores them runs
                // under the housing, which is a button the user can see and cannot press.
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: ChromeMetrics.panelGap) {
                        ControlRail(maxHeight: railMaxHeight(in: available.height)) {
                            modeButton
                            sourcesButton
                            desktopsButton
                            settingsButton
                        }
                        .reportChromeFrame(.leadingRail, into: $chromeFrames)
                        Spacer(minLength: 0)
                        ControlRail(maxHeight: railMaxHeight(in: available.height)) {
                            keysButton
                            shortcutsButton
                            escapeButton
                            tabButton
                            navigationButtons
                        }
                        .reportChromeFrame(.trailingRail, into: $chromeFrames)
                    }
                    .padding(.horizontal, ChromeMetrics.edgeInset)
                    .padding(.top, ChromeMetrics.edgeInset)

                    Spacer(minLength: 0)
                }

                statusBar.frame(maxWidth: 420)

                // The panel comes *before* the bottom row in this stack, not after it. Both are
                // bottom-anchored by the spacer above, so a panel added below the row pushed the
                // row up the screen — and the row is the pointer and the keys around it, which
                // then landed under the buttons in the rail. Adding it above means the panel
                // grows up over the picture and the controls it belongs to stay where they are.
                // The panel lies *over* the bottom controls rather than stacked above them.
                //
                // Stacked, it had to share the height with the wheel and the pointer column, and
                // what was left over on a landscape phone was not enough for two screens of
                // desktops — so it scrolled inside a box smaller than it needed and sat high up
                // the screen with its bottom edge nowhere near the bottom. Laid over them it can
                // be as tall as its contents and still end at the bottom edge, and the controls
                // it covers are one tap away from coming back, because a tap outside the panel
                // closes it.
                //
                // They share the width rather than fighting for it: the panel is centred and the
                // wheel and pointer column live at the two edges, so on any screen wide enough
                // to hold both, nothing is actually hidden.
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                        ScrollWheelView(
                            onScroll: wheelScroll(dy:),
                            label: wheelLabel,
                            position: interactionMode == .navigate ? zoomPosition : nil
                        )
                            .reportChromeFrame(.wheel, into: $chromeFrames)
                        Spacer(minLength: 0)
                        // Return above the pointer and Back beside it, so the thumb resting on
                        // the stick reaches both without crossing the screen.
                        pointerColumn
                            .reportChromeFrame(.pointer, into: $chromeFrames)
                            .offset(x: joystickColumnOffset)
                    }
                    .padding(.horizontal, ChromeMetrics.edgeInset)
                    .padding(.bottom, ChromeMetrics.bottomInset)

                    floatingPanel(available, isLandscape: true)
                        .padding(.bottom, ChromeMetrics.bottomInset)
                }
                // Anchored to the bottom by the frame, not by the spacer above. A spacer only
                // holds a column down while there is room to spare: the moment a panel made the
                // contents taller than the screen the spacer collapsed to nothing, and this
                // whole stack — which the enclosing ZStack aligns to the *top* — slid up the
                // screen with it. The panel ended up at the top and the pointer off the bottom.
                // An alignment pins the bottom edge whatever the content does.
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        } else {
            // Two layers, and the order between them is the whole of the arrangement. The pointer
            // is on the screen's own centre, which is the middle of the picture — so it is drawn
            // *under* the panel rather than over it. An overlay, which is what put it above
            // everything before, would have had a hundred-point disc swallowing the middle of any
            // panel the user opened, with its own controls unreachable underneath.
            ZStack(alignment: .bottom) {
                portraitPointer
                    .reportChromeFrame(.pointer, into: $chromeFrames)
                    // Centred across and sitting on the dock, rather than on the screen's own
                    // centre. `maxHeight: .infinity` with no alignment centres its content, so
                    // this filled the screen and put the joystick in the middle of both axes —
                    // the one place on a phone that no thumb can reach comfortably, and half a
                    // screen away from the bar it belongs to.
                    //
                    // The frame is still the whole screen. Only the content inside it has moved:
                    // the reported rect is measured from the control itself, so everything that
                    // reads it — the touches the canvas must not take — follows it here.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, dockHeight + ChromeMetrics.edgeInset + ChromeMetrics.panelGap)

                VStack(spacing: 0) {
                    statusBar
                    Spacer(minLength: 0)
                    // Above the dock, for the same reason as in landscape: below it there is
                    // nothing left to push it into.
                    floatingPanel(available, isLandscape: false)
                        .padding(.bottom, ChromeMetrics.panelGap)
                    portraitDock(width: available.width * ChromeMetrics.dockWidthFraction)
                        .reportChromeFrame(.dock, into: $chromeFrames)
                        .padding(.bottom, ChromeMetrics.edgeInset)
                }
            }
            .onAppear {
                // The wheel is landscape's, and its frame is in the canvas's coordinates rather
                // than the portait layout's — so rotating back leaves a rectangle of the screen
                // blocked for touches, over a control that is no longer there to receive them.
                chromeFrames[.wheel] = nil
            }
            .animation(Motion.settle, value: interactionMode)
        }
    }

    // MARK: - The six controls
    //
    // Written once and arranged twice: the landscape rails and the portrait bar are the same
    // six views in a different container. Two hand-maintained copies of this list is how the
    // two orientations drifted apart in the first place — the joystick was permanent in one and
    // opt-in in the other, and nothing said which was right.

    /// The switch the screen is organised around.
    ///
    /// Named for the mode it is *in*, not the one it would switch to: a control that advertises
    /// its destination while sitting in a state you cannot read is how a toggle comes to mean
    /// the opposite of what the user thought they pressed.
    private var modeButton: some View {
        RailButton(
            icon: interactionMode.symbol,
            label: interactionMode.label,
            // Filled only in drag & zoom. That is the mode that surprises if it is forgotten —
            // the picture behaving like a trackpad is what a glancing user already expects.
            //
            // Filling both was tried, on the grounds that a caption naming the current mode is
            // reporting a state and a state deserves a mark. On the device it read the other
            // way: a button that is never not lit stops being a mark, and it put the loudest
            // thing in the row at the head of it, permanently, in the mode most sessions spend
            // their whole time in.
            selected: interactionMode == .navigate
        ) {
            withAnimation(Motion.settle) { interactionMode = interactionMode.toggled }
        }
    }

    private var sourcesButton: some View {
        RailButton(
            icon: "rectangle.on.rectangle",
            label: "Share",
            selected: openPanel == .sources
        ) {
            withAnimation(Motion.settle) { openPanel = openPanel == .sources ? nil : .sources }
        }
    }

    /// Absent when the Mac has one desktop: a control that can only ever do nothing is clutter,
    /// and this is the one button that can drop out without leaving a hole in the meaning of the
    /// ones around it.
    @ViewBuilder
    private var desktopsButton: some View {
        if let info = model.catalog?.spaceInfo, DesktopsPanel.showsDesktops(info) {
            RailButton(
                icon: "rectangle.split.3x1",
                label: "Desktops",
                selected: openPanel == .desktops
            ) {
                withAnimation(Motion.settle) {
                    openPanel = openPanel == .desktops ? nil : .desktops
                }
            }
        }
    }

    /// Desktops, or the room it would have taken.
    ///
    /// The dock's open rows divide their width equally, which is what keeps the second row's
    /// buttons under the first row's. Desktops drops out when the Mac has one desktop and one
    /// screen, and a row of three where the row above has four would then have divided the width
    /// three ways and put its buttons half a button left of the ones they sit under. An empty
    /// cell is the same size as a full one, which is the whole of the fix.
    ///
    /// Here and not in the landscape rail, which is a column: a hole in that one would be a gap
    /// between two buttons rather than a column that stays in step.
    private var desktopsSlot: some View {
        ZStack { desktopsButton }
            .frame(maxWidth: .infinity)
    }

    /// Whether the desktops panel is worth offering at all.
    ///
    /// More than one desktop, **or** more than one screen. A second screen qualifies on its own
    /// even with a single desktop on it, because tapping that desktop is how the picture is moved
    /// to it — a control that can only ever do nothing is clutter, and this one can do something.
    private var keysButton: some View {
        RailButton(
            icon: model.showKeyboard ? "keyboard.fill" : "keyboard",
            // "Keyboard", not the "Keys" this began as. The caption is the only thing on screen
            // that says what an icon does, and "Keys" reads as a row of individual keys — the
            // arrows, the escape, the delete — which are all elsewhere on this very bar. What
            // this opens is the software keyboard.
            label: "Keyboard",
            selected: model.showKeyboard
        ) { model.showKeyboard.toggle() }
    }

    private var shortcutsButton: some View {
        RailButton(icon: "command", label: "Shortcuts", selected: openPanel == .shortcuts) {
            withAnimation(Motion.settle) {
                openPanel = openPanel == .shortcuts ? nil : .shortcuts
            }
        }
    }

    /// Escape and tab, on the rail rather than in the shortcuts panel.
    ///
    /// These are the two keys a remote desktop reaches for constantly and a software keyboard
    /// cannot send — dismissing a dialogue, moving between fields — and both were behind a
    /// toggle. The panel keeps its copies for the same reason the arrow strip keeps its return.
    private var escapeButton: some View {
        RailButton(icon: "escape", label: "Esc") { sendKey(keyCode: 53) }
    }

    private var tabButton: some View {
        RailButton(icon: "arrow.right.to.line", label: "Tab") { sendKey(keyCode: 48) }
    }

    /// The navigation keys, below the fold on the rail.
    ///
    /// Worth having permanently, not worth the top of the rail: they are reached for in bursts —
    /// nudging around a form, moving through a menu — while the buttons above them are reached
    /// for continuously. They are what the rail's scrolling is for.
    @ViewBuilder
    private var navigationButtons: some View {
        RailButton(icon: "chevron.up", label: "Up") { sendKey(keyCode: 126) }
        RailButton(icon: "chevron.down", label: "Down") { sendKey(keyCode: 125) }
        RailButton(icon: "chevron.left", label: "Left") { sendKey(keyCode: 123) }
        RailButton(icon: "chevron.right", label: "Right") { sendKey(keyCode: 124) }
        RailButton(icon: "delete.backward", label: "Delete") { sendKey(keyCode: 51) }
    }

    /// How tall a landscape rail may grow before its buttons scroll.
    ///
    /// Bounded by the pointer column at the foot of the same edge: the rail and that column share
    /// the right of the screen, and a rail allowed to run its full height would sit behind the
    /// joystick and the key stacked above it.
    ///
    /// Measured against the height the *chrome* is laid out in, not the canvas. The canvas ignores
    /// the safe area and the chrome does not, so the two differ by the home-indicator strip —
    /// sizing the rail against the larger number made it exactly that much too tall, and its last
    /// button ended up tucked under the return key.
    private func railMaxHeight(in availableHeight: CGFloat) -> CGFloat {
        guard availableHeight > 0 else { return .infinity }
        let pointerColumn = ChromeMetrics.quickKeySize + ChromeMetrics.panelGap + joystickRadius * 2
        let reserved = pointerColumn
            + ChromeMetrics.bottomInset
            + ChromeMetrics.edgeInset * 2
            + ChromeMetrics.panelGap
        return max(160, availableHeight - reserved)
    }

    /// How tall an open panel may grow before its contents have to scroll.
    ///
    /// A panel is laid out above the controls and grows upward, so an unbounded one on a short
    /// screen pushes its own first row off the top — out of reach, and with nothing on screen to
    /// suggest it was ever there. Bounded against the height the chrome is laid out in for the
    /// same reason ``railMaxHeight(in:)`` is: the canvas ignores the safe area and the chrome
    /// does not.
    private func ceiling(_ available: CGSize, _ isLandscape: Bool) -> CGFloat {
        guard available.height > 0 else { return .infinity }
        // A ceiling, not a target. The panel is as tall as its contents and no taller; this only
        // stops a pathological number of screens from pushing the panel's own first row off the
        // top of the display, where it would be both invisible and unreachable.
        //
        // What it has to stay clear of differs by orientation, and that is the whole reason this
        // takes a flag. In landscape the panel is drawn *over* the wheel and the pointer column,
        // so only the status pill above it needs room. In portrait it is stacked above them and
        // they are tall — the pointer column alone is 168 points, the dock another 70 — so they
        // are reserved, or the panel would cover controls that are still meant to be usable.
        //
        // Over-reserving in landscape is what kept the desktop tiles small: the ceiling was 279
        // points, two rows of chips and captions take 144 of it, and what was left made a tile 108
        // points wide however much width the panel had going spare.
        let reserved: CGFloat
        if isLandscape {
            reserved = ChromeMetrics.edgeInset * 2 + Self.statusBarHeight
        } else {
            // The dock and the pill, and not the pointer. The pointer sits above the dock now
            // rather than on the screen's own centre, so it is under the panel wherever the panel
            // ends — but it is not reserved either way, and that is the same decision as before
            // rather than a consequence of the move: the stick is drawn *under* the panel, so a
            // panel that covers it is one tap from being dismissed, while a panel kept clear of
            // it would be a panel too short to read.
            //
            // The *open* dock is reserved rather than the shut one, so that opening it while a
            // panel is up does not push the panel's own first row off the top of the display.
            reserved = ChromeMetrics.dockExpandedHeight
                + ChromeMetrics.panelGap
                + ChromeMetrics.edgeInset * 2
                + Self.statusBarHeight
        }
        return max(140, available.height - reserved)
    }

    /// The width a floating panel's contents have to work with.
    ///
    /// Worked out here rather than measured inside the panel: measuring it there made the number
    /// depend on the thing being sized, which is how the desktop tiles came out the same size as
    /// before the change that was supposed to grow them.
    private func panelContentWidth(_ available: CGSize) -> CGFloat {
        max(min(Self.panelWidth, available.width) - 20, 0)
    }

    /// The status pill, which is the one thing a panel must not be drawn over the top of.
    private static let statusBarHeight: CGFloat = 44

    private var settingsButton: some View {
        RailButton(icon: "gearshape", label: "Settings", selected: openPanel == .settings) {
            withAnimation(Motion.settle) { openPanel = openPanel == .settings ? nil : .settings }
        }
    }

    /// The one floating panel, whichever it is.
    ///
    /// One place, because four panels across two orientations is eight arrangements to keep in
    /// step, and the difference between them is what they contain rather than how they are framed.
    @ViewBuilder
    private func floatingPanel(_ available: CGSize, isLandscape: Bool) -> some View {
        // `alignment: .bottom` on every one of these, and it is load-bearing rather than tidy.
        // `maxHeight` makes a view *flexible* up to that height, so a panel whose contents are
        // shorter than the ceiling — the shortcuts panel nearly always — grows to the ceiling and
        // centres its contents inside it. Bottom-aligned, the frame is still the ceiling but the
        // panel sits at the bottom of it, which is where a panel belongs.
        switch openPanel {
        case .shortcuts:
            shortcutsPanel
                .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case .desktops:
            DesktopsPanel(
                chromeFrames: $chromeFrames,
                onSelect: closePanelAfterSelection,
                maximumHeight: ceiling(available, isLandscape),
                contentWidth: panelContentWidth(available)
            )
            .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case .sources:
            SourcesPanel(chromeFrames: $chromeFrames, onSelect: closePanelAfterSelection)
                .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case .settings:
            SettingsPanel(chromeFrames: $chromeFrames) {
                withAnimation(Motion.settle) { openPanel = .sources }
            }
            .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case nil:
            EmptyView()
        }
    }

    /// The widest a floating panel may be. Wide enough for a source picker's names and icons to be
    /// scanned, narrow enough that it stays clear of the rails on a phone held sideways.
    private static let panelWidth: CGFloat = 520

    /// Puts the panel away once the user has picked something from it, if that is what they asked
    /// for.
    ///
    /// Shortcuts is exempt and always will be, whatever the setting says: its buttons are momentary
    /// key presses rather than choices, and a panel that shut after every keystroke would have to
    /// be reopened for the next one.
    private func closePanelAfterSelection() {
        guard hidesPanelAfterSelect else { return }
        withAnimation(Motion.settle) { openPanel = nil }
    }

    /// Return, beside the pointer rather than inside the shortcuts panel — see ``QuickKeyButton``
    /// for why it earns a permanent place. The arrow strip in the panel keeps its own copy: that
    /// one is for when the user is already in there moving around a window.
    private var returnKey: some View {
        // Captioned "Enter" and not "Return", though the key it sends is Return — see
        // ``SessionModel/pressReturn()``. The caption's job is to be the word the user reaches for,
        // and on a phone this key is Enter to everyone who is not reading Apple's keyboard
        // documentation. The spoken name matches the visible one, so VoiceOver agrees with the
        // screen.
        QuickKeyButton(icon: "return", label: "Enter", caption: "Enter") { model.pressReturn() }
    }

    /// Back, to the left of the pointer.
    ///
    /// ⌘← — an arrow rather than the bracket, and that choice is the whole point of this comment.
    ///
    /// ⌘[ is the other spelling of Back and the one that first went here, and it does not work
    /// everywhere: an arrow key reports the same key code on every keyboard layout, while `[`
    /// is matched by the *character* the key produces, so on a layout that puts the bracket
    /// behind a modifier the shortcut never fires. Back is ⌘← in Safari, Chrome, Finder and
    /// System Settings alike, and the arrow cannot be misread by a layout.
    ///
    /// A remote desktop has no history of its own to walk, so the only honest thing this button
    /// can mean is what the Mac under it already means by Back.
    ///
    /// Smaller than Return and off its axis, because it is not the key that commits: it is the
    /// one reached for in passing, so it sits beside the stick rather than above it.
    private var backKey: some View {
        QuickKeyButton(icon: "chevron.backward", label: "Back", size: 46, caption: "Back") {
            sendKey(keyCode: 123, modifiers: [.command])
        }
    }

    /// Return above the pointer, Delete beside it.
    ///
    /// Trailing-aligned, with the top row framed to the stick's own width, so Return stays on the
    /// stick's axis now that the column is wider than the pointer is. Centred in the column
    /// instead, it would sit off to the left of the thing it belongs to.
    ///
    /// Shared by both layouts rather than written twice: the two used to be copies of each other,
    /// which is how a control ends up in one orientation and not the other.
    private var pointerColumn: some View {
        VStack(alignment: .trailing, spacing: ChromeMetrics.panelGap) {
            returnKey
                .frame(width: joystickRadius * 2)
            HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                backKey
                joystick()
            }
        }
    }

    private func joystick(radius: CGFloat = joystickRadius) -> some View {
        JoystickView(
            onMove: sendJoystick,
            onTap: sendJoystickClick,
            onRightClick: sendJoystickRightClick,
            pointSize: model.capturePointSize,
            radius: radius
        )
    }

    /// How far the pointer column sits past the rail's edge inset.
    ///
    /// Centred on the rail above it, which is what "in line" means here. The pointer is a 100pt
    /// circle and a rail is 64pt wide, so aligning their trailing edges — which the shared edge
    /// inset does on its own — leaves the two centres 18pt apart, and an 18pt disagreement down
    /// a column reads as the whole bottom of the screen being askew.
    ///
    /// Applied to the whole column rather than to the joystick alone, so the key stacked above it
    /// stays centred on the same axis.
    private var joystickColumnOffset: CGFloat {
        (joystickRadius * 2 - ChromeMetrics.panelWidth) / 2
    }

    /// The one panel: everything that is not worth a permanent button.
    ///
    /// One panel rather than four, and only ever one open at a time. Having several that could
    /// be up at once, with no rule about which won, was most of what made the old screen feel
    /// like it was moving under the user.
    private var shortcutsPanel: some View {
        VStack(spacing: 8) {
            if model.showKeyboard, !model.typedPreview.isEmpty {
                HStack {
                    Text(model.typedPreview)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        // Head-truncate so the most-recently-typed characters stay visible
                        // when the preview is wider than the available space.
                        .truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            MacroBar()

            HStack(spacing: 10) {
                ModifierBar()
                Spacer()
                Button(model.keyboardMode.label) {
                    model.setKeyboardMode(model.keyboardMode == .unicode ? .keycode : .unicode)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }

            arrowStrip
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// The arrow keys, plus the two keys a software keyboard cannot send as navigation.
    ///
    /// A single row rather than the inverted T of a physical cluster: this shares a panel with
    /// the macros and the modifiers, and three rows of keys would make it taller than the thing
    /// it is helping with.
    private var arrowStrip: some View {
        HStack(spacing: 4) {
            compactKeyButton(icon: "chevron.left", keyCode: 123)
            compactKeyButton(icon: "chevron.up", keyCode: 126)
            compactKeyButton(icon: "chevron.down", keyCode: 125)
            compactKeyButton(icon: "chevron.right", keyCode: 124)
            compactKeyButton(icon: "return", keyCode: 36) { model.pressReturn() }
            compactKeyButton(icon: "delete.backward", keyCode: 51)
        }
    }

    /// How tall the dock stands at the moment.
    ///
    /// The one piece of portrait chrome whose height changes, and the pointer above it is placed
    /// from it rather than from a second number that would have to be kept in step. Read from the
    /// same two constants the dock is built from, so opening it lifts the pointer by exactly the
    /// row that appeared.
    private var dockHeight: CGFloat {
        dockExpanded ? ChromeMetrics.dockExpandedHeight : ChromeMetrics.dockCollapsedHeight
    }

    /// The same controls as the landscape rails, in a bar that opens like the status pill does.
    ///
    /// Eight buttons across a phone held upright is a bar with no room left for the picture, and
    /// four of those eight are reached for continuously while the other four are not. So the
    /// shut rail is the four that are, and the chevron at the end of the row opens it onto the
    /// rest — the same gesture, the same spring and the same morphing corner as the pill above
    /// it, because they are the same kind of object: a bar of glass that grows when asked.
    ///
    /// The two rows share a column grid, the chevron's column included. Row two's four buttons
    /// are inset by exactly the chevron's width so that they line up under row one's — a second
    /// row whose buttons sat half a button to the left of the ones above it is the sort of thing
    /// nobody can name and everybody can see.
    private func portraitDock(width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if dockExpanded {
                VStack(spacing: ChromeMetrics.buttonGap) {
                    HStack(spacing: 0) {
                        modeButton
                        sourcesButton
                        keysButton
                        shortcutsButton
                        dockToggle
                    }
                    HStack(spacing: 0) {
                        desktopsSlot
                        escapeButton
                        tabButton
                        settingsButton
                        dockEmptyCell
                    }
                    // The keys the landscape rail keeps below its fold, which portrait had no
                    // equivalent for at all. Five of them and five columns, so each lands in a
                    // column of its own and the row needs no empty cell to stay in step — which
                    // is the whole reason five is the number (see ``ChromeMetrics/dockColumns``).
                    HStack(spacing: 0) {
                        navigationButtons
                    }
                }
            } else {
                HStack(spacing: 0) {
                    modeButton
                    sourcesButton
                    keysButton
                    shortcutsButton
                    dockToggle
                }
            }
        }
        .padding(.vertical, ChromeMetrics.railPadding)
        .padding(.horizontal, ChromeMetrics.railSidePadding)
        .frame(width: width)
        .clipShape(dockShape)
        .glassEffect(.regular, in: dockShape)
    }

    /// The dock's outline, in whichever state it is in — see ``pillShape``, which this is a
    /// second reading of. The buttons divide whatever width they are given, so the two states
    /// differ in height alone; the corner is what tells the eye the bar has opened rather than
    /// been swapped for a taller one.
    private var dockShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: dockExpanded
                ? ChromeMetrics.dockExpandedRadius
                : ChromeMetrics.dockCollapsedRadius,
            style: .continuous
        )
    }

    /// The dock's own chevron: the one thing in the row that is not a control for the Mac.
    ///
    /// The buttons fill their rows between them, so there is no gap left to tap — an expanding
    /// bar of solid controls has nowhere to put the gesture unless it is given a cell of its
    /// own. It is wordless because it says nothing about the Mac; it only says there is more
    /// bar.
    ///
    /// A whole column, not the narrow slot it began as. The grid it sits in is five even cells,
    /// and a chevron on a column of its own is what lets the row below it be five keys rather
    /// than four keys and a gap. The extra width costs nothing the row was using: it is the
    /// tap target for the one control here that has no caption to aim at.
    private var dockToggle: some View {
        Button {
            withAnimation(Motion.morph) { dockExpanded.toggle() }
        } label: {
            Image(systemName: dockExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(dockExpanded ? "Hide the other controls" : "Show the other controls")
    }

    /// The chevron's column, empty, in the rows below the one the chevron is in.
    ///
    /// Flexible rather than a fixed width, so it is a column like every other cell in the grid
    /// and the buttons either side of it land where they would if it held a button.
    ///
    /// Given a height, and that is load-bearing rather than tidy. `Color` is flexible in *both*
    /// axes, and an unheighted one answers its row's height proposal with whatever it is handed
    /// — so the row grows to fill the screen and the dock opens to the height of the display.
    /// Only the open dock has such a cell, which is why a bar of the right height went wrong
    /// exactly when it was opened.
    private var dockEmptyCell: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: ChromeMetrics.buttonHeight)
    }

    /// The pointer in portrait: the stick above the dock, with the two keys either side of it.
    ///
    /// Return moves off the stick's axis to its right, and Back keeps the left, so the row is
    /// only ever one control tall — a key stacked above the stick would be a key over the middle
    /// of the picture, which is the part of the Mac the user is trying to see.
    ///
    /// Both keys are given the same frame whatever size they are drawn at, so the row balances
    /// around the stick and the stick lands on the centre exactly. Framed to their own widths,
    /// the smaller Back would leave the stick seven points off the middle — which is the amount
    /// that reads as the screen being slightly crooked rather than as a mistake.
    private var portraitPointer: some View {
        HStack(alignment: .center, spacing: ChromeMetrics.panelGap) {
            backKey
                .frame(width: ChromeMetrics.quickKeySize, height: ChromeMetrics.quickKeySize)
            joystick()
            returnKey
                .frame(width: ChromeMetrics.quickKeySize, height: ChromeMetrics.quickKeySize)
        }
    }

    /// Pixels straight through: the wheel has its own travel-to-pixels scale, unlike the
    /// two-finger gesture which is doubled here because a point of finger travel moving one
    /// pixel would make scrolling a page take several swipes.
    private func sendScroll(dy: CGFloat) {
        model.send(.scroll(dx: 0, dy: Double(dy)))
    }

    /// What the wheel does, which is the mode's business rather than the wheel's.
    ///
    /// In view & scroll it scrolls the Mac — the same thing the two-finger drag does, on a control
    /// that can be found without aiming two fingers at the glass. In drag & zoom there is nothing
    /// to scroll and a picture to resize, so it zooms. The pinch still does the same thing there:
    /// this is a second way to ask, not a replacement for the first.
    private func wheelScroll(dy: CGFloat) {
        switch interactionMode {
        case .control: sendScroll(dy: dy)
        case .navigate: zoomByWheel(dy)
        }
    }

    /// What the wheel is for at the moment, for anyone listening rather than looking.
    private var wheelLabel: String {
        interactionMode == .control ? "Scroll the Mac" : "Zoom the picture"
    }

    /// How far up its track the wheel's gauge should be filled, 0 to 1.
    ///
    /// Logarithmic, because zoom is: the difference between 1× and 2× is the same *step* as
    /// between 4× and 8×, and a linear gauge would spend the whole top half of its length on the
    /// last few factors while the bottom half covered everything below 2×. Measured, it makes each
    /// equal length of track an equal doubling.
    private var zoomPosition: CGFloat {
        let low = log(minimumZoom)
        let high = log(maximumZoom)
        guard high > low, zoom > 0 else { return 0 }
        return min(max((log(zoom) - low) / (high - low), 0), 1)
    }

    /// How far one pixel of wheel travel moves the zoom.
    ///
    /// Multiplicative, because zoom is: a fixed step is an enormous change at 1× and invisible at
    /// 6×, and a finger on the wheel has no idea which end of the range it is at. A full drag of
    /// the track works out at roughly six times either way — enough to be worth the space, not so
    /// much that it overshoots what the user aimed at.
    private static let zoomPerPixel: CGFloat = 1.0 / 400

    /// Resizes the picture by a wheel drag. Up is closer, which is the way the two-finger pinch
    /// already goes.
    ///
    /// Zooming back out past the fit drops the pan, exactly as the pinch does: the pan limits
    /// shrink with the picture, so at 1× every offset is already out of bounds and holding one
    /// would leave the picture pinned off-centre for no reason the user can see.
    private func zoomByWheel(_ pixels: CGFloat) {
        zoom = min(max(zoom * exp(-pixels * Self.zoomPerPixel), minimumZoom), maximumZoom)
        // Re-clamped, not reset — see `onZoom`. The wheel is a finer control than a pinch and
        // makes the snap at the end of a zoom-out easier to produce, not harder.
        pan = clampedPan(pan)
    }

    private func sendJoystick(_ travel: CGSize) {
        model.send(.joystickMove(dx: Double(travel.width), dy: Double(travel.height)))
    }

    private func sendJoystickClick() {
        model.send(.mouseDown(button: .left))
        model.send(.mouseUp(button: .left))
    }

    private func sendJoystickRightClick() {
        model.send(.mouseDown(button: .right))
        model.send(.mouseUp(button: .right))
    }

    private func sendKey(keyCode: UInt16, modifiers: Modifiers = []) {
        model.send(.keyDown(keyCode: keyCode, modifiers: modifiers))
        model.send(.keyUp(keyCode: keyCode, modifiers: modifiers))
    }

    /// - Parameter action: what the key does, when sending it is not the whole of it — Return also
    ///   clears the typed preview. Defaults to the plain press this strip uses for everything else.
    private func compactKeyButton(
        icon: String,
        keyCode: UInt16,
        action: (() -> Void)? = nil
    ) -> some View {
        Button { (action ?? { sendKey(keyCode: keyCode) })() } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.86))
    }

    // MARK: - Keyboard input bar

    private var keyboardInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(model.typedPreview.isEmpty ? "Typing…" : model.typedPreview)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(model.typedPreview.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.showKeyboard = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous)
        )
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, ChromeMetrics.edgeInset)
    }

}

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

    @State private var openPanel: Panel?
    @State private var statusBarExpanded = true

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

    var body: some View {
        // `Environment` gives the object but no projected value, so a local `@Bindable` is
        // what turns `model.showKeyboard` into something the keyboard view can bind to.
        @Bindable var model = model
        return GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            ZStack {
                ColorPalette.backdrop.ignoresSafeArea()

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

    private var statusBar: some View {
        Group {
            if statusBarExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // ── Row 1: identity + clock + quit ──────────────────────────────
                    HStack(spacing: 10) {
                        Circle().fill(ColorPalette.ink).frame(width: 7, height: 7)
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                HStack(spacing: 8) {
                    Circle().fill(ColorPalette.ink).frame(width: 6, height: 6)
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
                .contentShape(Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: statusBarExpanded)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 10)
        // The same inset as the rails, so the pill and the panels hang from one line.
        .padding(.top, ChromeMetrics.edgeInset)
        .reportChromeFrame(.statusBar, into: $chromeFrames)
        .task(id: model.phase) {
            // Expand a moment when the session comes up, then collapse.
            guard model.phase == .ready else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                statusBarExpanded = true
            }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                statusBarExpanded = false
            }
        }
    }

    private var connectionPathChip: some View {
        Text(model.connectionPath?.rawValue ?? "—")
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            statusBarExpanded = true
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                statusBarExpanded = false
            }
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
            VStack(spacing: 0) {
                statusBar
                Spacer(minLength: 0)
                // Above the controls, for the same reason as in landscape: below them it would
                // push the wheel and the pointer up into the dock.
                floatingPanel(available, isLandscape: false)
                // Wheel on the left; joystick floats centered above the dock via overlay.
                HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                    ScrollWheelView(
                        onScroll: wheelScroll(dy:),
                        label: wheelLabel,
                        position: interactionMode == .navigate ? zoomPosition : nil
                    )
                    .reportChromeFrame(.wheel, into: $chromeFrames)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ChromeMetrics.edgeInset)
                .padding(.bottom, ChromeMetrics.edgeInset)
                portraitDock
                    .reportChromeFrame(.dock, into: $chromeFrames)
            }
            .overlay(alignment: .bottom) {
                pointerColumn
                    .reportChromeFrame(.pointer, into: $chromeFrames)
                    .padding(.bottom, ChromeMetrics.buttonHeight + ChromeMetrics.railPadding * 2 + ChromeMetrics.edgeInset * 2)
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
            // Mint only in drag & zoom. That is the mode that surprises if it is forgotten —
            // the picture behaving like a trackpad is what a glancing user already expects.
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

    /// Whether the desktops panel is worth offering at all.
    ///
    /// More than one desktop, **or** more than one screen. A second screen qualifies on its own
    /// even with a single desktop on it, because tapping that desktop is how the picture is moved
    /// to it — a control that can only ever do nothing is clutter, and this one can do something.
    private var keysButton: some View {
        RailButton(
            icon: model.showKeyboard ? "keyboard.fill" : "keyboard",
            label: "Keys",
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
            reserved = ChromeMetrics.quickKeySize
                + ChromeMetrics.panelGap
                + joystickRadius * 2
                + ChromeMetrics.bottomInset
                + ChromeMetrics.edgeInset * 2
                + ChromeMetrics.buttonHeight + ChromeMetrics.railPadding * 2
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

    /// The same six controls as the landscape rails, scrolled rather than stacked.
    private var portraitDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                modeButton
                sourcesButton
                desktopsButton
                keysButton
                shortcutsButton
                escapeButton
                tabButton
                settingsButton
            }
            // One width for all of them, and the rail's own at that, so the bar reads as evenly
            // divided. Left to size themselves they are as wide as their captions — "Esc" beside
            // "Shortcuts" — and the gaps look random even though the spacing between them is
            // identical, which is the tell that it is the widths and not the spacing.
            .environment(\.railButtonWidth, ChromeMetrics.panelWidth)
            .padding(.horizontal, 4)
        }
        // Sized from the buttons it holds rather than chosen. This was a fixed 56 while the
        // buttons were 46, which left room to spare; raising them to 62 then hung the selected
        // fill out of the top and bottom of the dock, and a bar that cannot drift away from the
        // thing inside it is the cure.
        .frame(height: ChromeMetrics.buttonHeight + ChromeMetrics.railPadding * 2)
        // The same stadium as the vertical rails, for the same reason and from the same two
        // numbers, so the two orientations cannot disagree about what a rail looks like.
        .glassEffect(.regular, in: Capsule())
        .clipShape(Capsule())
        // Floating, not welded to the glass. Every other surface in this app is a panel with a
        // margin around it, and a bar running edge to edge would be the one piece of chrome that
        // was a different kind of object from all the rest.
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.bottom, ChromeMetrics.edgeInset)
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

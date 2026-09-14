import RemoteCore
import SwiftUI
import UIKit

/// A piece of chrome that owns the touches that land on it.
private enum ChromeRegion: Hashable {
    case leadingRail
    case trailingRail
    /// The scroll wheel, on its own rather than as part of the row it sits in.
    ///
    /// A row is mostly empty space between its controls, and a region that covers the whole row
    /// claims all of it: touches in the gap would stop reaching the Mac, and — worse — a tap
    /// beside an open panel would count as landing on chrome and so would neither dismiss the
    /// panel nor click anything. Reporting the controls is what makes the gaps behave like the
    /// picture they are.
    case wheel
    /// The joystick with Return and Back above and beside it.
    case pointer
    case panel
    case statusBar
    case dock
}

/// Reports where a piece of chrome is, in the canvas's coordinates.
///
/// The gesture surface needs to be told, because it cannot work it out: it is a UIKit view and
/// the chrome is SwiftUI drawing on top of it, so a touch aimed at a button is delivered to the
/// canvas as well. See ``CanvasGeometry/isBlocked``.
private struct ChromeFrameReporter: ViewModifier {
    let region: ChromeRegion
    @Binding var frames: [ChromeRegion: CGRect]

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { rect in
            // Guarded, because writing state from a layout callback that state feeds back into
            // is how a layout loop starts.
            if frames[region] != rect { frames[region] = rect }
        }
    }
}

private extension View {
    func reportChromeFrame(
        _ region: ChromeRegion,
        into frames: Binding<[ChromeRegion: CGRect]>
    ) -> some View {
        modifier(ChromeFrameReporter(region: region, frames: frames))
    }
}

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
    @State private var showSheet = false
    @State private var showSources = false
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
        .sheet(isPresented: $showSheet) { SessionSheet() }
        .sheet(isPresented: $showSources) { SourceBrowserSheet() }
        // A hidden panel reports nothing, so its last frame would go on blocking touches in a
        // region that no longer has anything in it.
        .onChange(of: openPanel) { _, panel in
            if panel == nil { chromeFrames[.panel] = nil }
        }
    }

    // MARK: - Picture

    private var video: some View {
        VideoLayerView(renderer: model.renderer)
            .scaleEffect(effectiveZoom, anchor: .center)
            .offset(pan)
            .ignoresSafeArea()
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
                if zoom <= 1.01 { pan = .zero }
            },
            onPanCanvas: { translation in
                pan = clampedPan(
                    CGSize(width: pan.width + translation.width,
                           height: pan.height + translation.height)
                )
            },
            onSizeChange: { canvasSize = $0 },
            interactionMode: interactionMode,
            blockedRegions: blockedRegions,
            isPanelOpen: openPanel != nil,
            onDismissPanel: { withAnimation(Motion.settle) { openPanel = nil } }
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
    private var panLimit: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let rect = CanvasGeometry.videoRect(bounds: canvasSize, pixelSize: model.capturePixelSize)
        return CGSize(
            width: max(0, (rect.width * effectiveZoom - canvasSize.width) / 2),
            height: max(0, (rect.height * effectiveZoom - canvasSize.height) / 2)
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
                    Spacer()
                    sessionClock
                    if let latency = model.latencyMilliseconds {
                        Text("\(Int(latency.rounded())) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ColorPalette.reading(latency))
                    }
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
                    // The session's only way out, and it lives here rather than on a rail: this
                    // pill is the one piece of chrome that is always on screen, expanded or not,
                    // so ending a session is never something the user has to go looking for.
                    Button { model.disconnect() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(ColorPalette.ink)
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.88))
                    .accessibilityLabel("Disconnect")
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(ColorPalette.ink).frame(width: 6, height: 6)
                    Text(model.hostName ?? "Mac")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
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
            }
        }
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 10)
        // The same inset as the rails, so the pill and the panels hang from one line.
        .padding(.top, ChromeMetrics.edgeInset)
        .reportChromeFrame(.statusBar, into: $chromeFrames)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: statusBarExpanded)
        .task(id: model.phase) {
            // Collapse to compact pill a few seconds after the session is live.
            guard model.phase == .ready else { return }
            statusBarExpanded = true
            try? await Task.sleep(for: .seconds(4))
            withAnimation { statusBarExpanded = false }
        }
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
        statusBarExpanded = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { statusBarExpanded = false }
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
                VStack(spacing: ChromeMetrics.panelGap) {
                    // No spacer. The bottom edge is held by the frame's alignment below, and a
                    // spacer in front of the same content is a second thing trying to do the same
                    // job — the one that gets it wrong the moment the content outgrows the screen,
                    // because a spacer can only push while there is slack to push into.

                    // The panel gets a row of its own, centred on the screen. It used to open in
                    // the gap between the wheel and the pointer, which sounds like the middle and
                    // is not: those two are different widths, so the middle of what is left
                    // between them sits off to the left of the middle of the screen.
                    if openPanel == .shortcuts {
                        shortcutsPanel.frame(maxWidth: 520)
                    }
                    if openPanel == .desktops {
                        desktopStrip.frame(maxWidth: 520, maxHeight: panelHeightLimit(available))
                    }

                    HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                        ScrollWheelView(onScroll: wheelScroll(dy:), label: wheelLabel)
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
                if openPanel == .shortcuts {
                    shortcutsPanel.frame(maxHeight: panelHeightLimit(available))
                }
                if openPanel == .desktops {
                    desktopStrip.frame(maxHeight: panelHeightLimit(available))
                }
                // Wheel on the left, pointer on the right, where each thumb already is.
                HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                    ScrollWheelView(onScroll: wheelScroll(dy:), label: wheelLabel)
                        .reportChromeFrame(.wheel, into: $chromeFrames)
                    Spacer(minLength: 0)
                    pointerColumn
                        .reportChromeFrame(.pointer, into: $chromeFrames)
                        .offset(x: joystickColumnOffset)
                }
                .padding(.horizontal, ChromeMetrics.edgeInset)
                .padding(.bottom, ChromeMetrics.edgeInset)
                portraitDock
                    .reportChromeFrame(.dock, into: $chromeFrames)
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
        RailButton(icon: "rectangle.on.rectangle", label: "Share") {
            showSources = true
        }
    }

    /// Absent when the Mac has one desktop: a control that can only ever do nothing is clutter,
    /// and this is the one button that can drop out without leaving a hole in the meaning of the
    /// ones around it.
    @ViewBuilder
    private var desktopsButton: some View {
        if let info = model.catalog?.spaceInfo, showsDesktops(info) {
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
    private func showsDesktops(_ info: SpaceInfo) -> Bool {
        info.totalCount > 1 || info.displays.count > 1
    }

    /// The desktops of every screen, as pictures.
    ///
    /// Pictures rather than a list of numbers because the question being asked is "which one had
    /// my browser on it", and a number cannot answer that. Each tile is a snapshot taken when that
    /// desktop was last active — see ``SpacePreview`` for why it cannot be live.
    ///
    /// One row per screen. Spaces are per-display, so a single flat strip of five tiles would be
    /// five unlabelled pictures two of which are called "Desktop 1" — the grouping is the answer
    /// to which screen a tile belongs to, and the chip is the label for it. The chip only appears
    /// when there is more than one screen to tell apart.
    @ViewBuilder
    private var desktopStrip: some View {
        if let info = model.catalog?.spaceInfo, showsDesktops(info) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Desktops")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // Scrolls when it has to, which is what keeps a third screen or a fourth from
                // pushing the first row off the top of the panel and out of reach.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(info.displays) { display in
                            VStack(alignment: .leading, spacing: 6) {
                                if info.displays.count > 1 {
                                    displayChip(display)
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        // Offsets rather than `1...count`, which is an empty range
                                        // when a display reports nothing and traps on the way.
                                        ForEach(0..<display.count, id: \.self) { offset in
                                            desktopTile(
                                                display: display,
                                                index: offset + 1,
                                                showsScreenName: info.displays.count > 1
                                            )
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 10)
            .reportChromeFrame(.panel, into: $chromeFrames)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// A screen's name, on its own line above that screen's desktops.
    ///
    /// Above rather than beside, and hugging its text rather than given a width. Display names are
    /// arbitrary user-facing strings — "Built-in Retina Display" is a normal one and a phone panel
    /// is narrow — so sitting beside the tiles would mean a fixed width, and a fixed width would
    /// mean truncating real names to fit around a thumbnail. Given the whole row's width there is
    /// nothing to truncate. Each row still starts at the same left edge, which is what keeps the
    /// panel reading as rows rather than as a ragged list.
    ///
    /// The name is read from the catalogue rather than sent alongside the desktops: it is the same
    /// `NSScreen.localizedName` the source picker shows, so the two can never describe one screen
    /// two ways.
    private func displayChip(_ display: SpaceDisplay) -> some View {
        Text(displayName(display))
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(ColorPalette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ColorPalette.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(ColorPalette.ink.opacity(0.15))
            }
    }

    private func displayName(_ display: SpaceDisplay) -> String {
        model.catalog?.descriptor(for: .display(display.displayID))?.title ?? "Display"
    }

    private func desktopTile(display: SpaceDisplay, index: Int, showsScreenName: Bool) -> some View {
        let isCurrent = index == display.current
        let label = "Desktop \(index)\(isCurrent ? ", current" : "")"
        return Button {
            switchToDesktop(display: display, index: index)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ColorPalette.surface)

                    if let data = display.preview(for: index)?.jpegData,
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // An empty tile is the truth: this desktop has not been on screen since
                        // the host started, so there is no picture of it to show. A placeholder
                        // image would be a picture of a desktop that does not exist.
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 104, height: 65)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isCurrent ? ColorPalette.accent : ColorPalette.ink.opacity(0.18),
                            lineWidth: isCurrent ? 2 : 1
                        )
                }

                Text("Desktop \(index)")
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? ColorPalette.accent : Color.secondary)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(showsScreenName ? "\(displayName(display)) \(label)" : label)
    }

    /// Reveals a desktop, and takes the picture with it. Always both.
    ///
    /// A desktop tile names a *screen* as well as a desktop, so tapping one is a statement about
    /// where to look. Switching only the Space left the user watching one screen while another
    /// rearranged itself off-camera — and when the source was a window rather than a display,
    /// which follows its window wherever that window is, nothing visible happened at all.
    ///
    /// This used to insist the current source be a display first, on the theory that a user
    /// watching one window had asked to watch *that*. That was the wrong call: the tap is a
    /// destination, and refusing to go there is what made the tiles look broken.
    ///
    /// The Space goes out first so the move reads as one thing. The Mac rearranges the desktop
    /// that was asked for while the picture is still where it was, and the picture then arrives on
    /// it already showing the right thing; the other order shows the screen being left, and then a
    /// second jump.
    private func switchToDesktop(display: SpaceDisplay, index: Int) {
        model.send(.switchToSpace(display: display.displayID, index: index))

        let source = CaptureSource.display(display.displayID)
        guard model.activeSourceID != source.stableID else { return }
        model.send(.setCaptureSource(source))
    }

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
    private func panelHeightLimit(_ available: CGSize) -> CGFloat {
        guard available.height > 0 else { return .infinity }
        let controls = ChromeMetrics.quickKeySize
            + ChromeMetrics.panelGap
            + joystickRadius * 2
            + ChromeMetrics.bottomInset
            + ChromeMetrics.edgeInset * 2
        // The status line above and the portrait dock below. Whichever orientation is being laid
        // out has one of them beside the panel, and reserving for both costs a little height here
        // rather than leaving two numbers that quietly disagree about which edge they measure from.
        let ends = ChromeMetrics.buttonHeight + ChromeMetrics.edgeInset * 2
        // Capped at a share of the screen as well as at the room left over. A panel that grows to
        // fill whatever gap it is given reaches the top of a short landscape display and reads as
        // though it were anchored there — which is the opposite of where a panel belongs, and no
        // amount of bottom-aligning the stack it sits in changes how that looks.
        return max(120, min(available.height - controls - ends, available.height * 0.42))
    }

    private var settingsButton: some View {
        RailButton(icon: "gearshape", label: "Settings") { showSheet = true }
    }

    /// Return, beside the pointer rather than inside the shortcuts panel — see ``QuickKeyButton``
    /// for why it earns a permanent place. The arrow strip in the panel keeps its own copy: that
    /// one is for when the user is already in there moving around a window.
    private var returnKey: some View {
        QuickKeyButton(icon: "return", label: "Return") { sendKey(keyCode: 36) }
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
        QuickKeyButton(icon: "chevron.backward", label: "Back", size: 46) {
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
            compactKeyButton(icon: "return", keyCode: 36)
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
        .frame(height: 56)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous)
        )
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
        if zoom <= 1.01 { pan = .zero }
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

    private func compactKeyButton(icon: String, keyCode: UInt16) -> some View {
        Button { sendKey(keyCode: keyCode) } label: {
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

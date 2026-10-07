import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// A relative pointer control: the joystick handles the small corrections absolute touch is wrong for. Deltas are per unit time, not per touch sample, since a per-sample delta would double cursor speed on a 120 Hz display.
struct JoystickView: View {
    var onMove: (CGSize) -> Void
    var onTap: (() -> Void)?
    var onRightClick: (() -> Void)?
    /// Fired on a second tap inside the double-tap window: the host's own control, not a Mac gesture (steps the pointer speed).
    var onDoubleTap: (() -> Void)?
    var speedText: String?
    var pointSize: CGSize
    var radius: CGFloat = 54

    private static let travelPerSecond = 1.5
    /// A gap longer than this is a new gesture: otherwise the first sample of a drag carries all the time since the last and the cursor jumps.
    private static let maximumSampleGap: TimeInterval = 0.05
    private static let longPressDuration: TimeInterval = 0.45
    private static let tapMaxDisplacement: CGFloat = 8
    private static let doubleTapWindow: TimeInterval = 0.3

    @State private var knob: CGSize = .zero
    @State private var lastSample: Date?
    @State private var touchStart: Date?
    @State private var isLongPress = false
    @State private var holdTask: Task<Void, Never>?
    @State private var lastTapEndedAt: Date?
    @State private var pendingClick: Task<Void, Never>?
    @State private var pendingDx: Double = 0
    @State private var pendingDy: Double = 0
    @State private var drainTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassSurface(in: Circle(), interactive: true)
                .frame(width: radius * 2, height: radius * 2)

            Circle()
                .fill(ColorPalette.ink.opacity(0.85))
                .frame(width: 40, height: 40)
                .overlay {
                    Circle()
                        .strokeBorder(ColorPalette.ink, lineWidth: 2)
                        .scaleEffect(isLongPress ? 1.4 : 1)
                        .opacity(isLongPress ? 1 : 0)
                }
                .offset(knob)
                .shadow(radius: 3)
                // Deliberately not animated on `knob`: it is set on every sample of a drag, which started a spring a hundred-odd times a second on the main thread. The return to centre is animated in `onEnded`.
                .animation(Motion.tap, value: isLongPress)

            if let speedText {
                Text(speedText)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if touchStart == nil {
                        touchStart = Date()
                        startDraining()
                        let task = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(Self.longPressDuration))
                            if !Task.isCancelled { isLongPress = true }
                        }
                        holdTask = task
                    }
                    let raw = CGSize(
                        width: value.location.x - radius,
                        height: value.location.y - radius
                    )
                    // Cancel the long-press timer once the finger has moved enough to be a drag, or a slow short drag right-clicks on release.
                    if hypot(raw.width, raw.height) > Self.tapMaxDisplacement {
                        holdTask?.cancel()
                        holdTask = nil
                        isLongPress = false
                    }
                    // Clamped to the ring so a finger wandering off the pad keeps full deflection instead of an implausibly large jump.
                    let distance = max(hypot(raw.width, raw.height), 0.0001)
                    let limited = distance > radius
                        ? CGSize(width: raw.width * radius / distance, height: raw.height * radius / distance)
                        : raw
                    knob = limited
                    if !isLongPress { emit(limited) }
                }
                .onEnded { value in
                    holdTask?.cancel()
                    holdTask = nil
                    stopDraining()
                    let wasLong = isLongPress
                    withAnimation(Motion.settle) { knob = .zero }
                    lastSample = nil
                    touchStart = nil
                    isLongPress = false

                    let displacement = hypot(value.translation.width, value.translation.height)
                    if displacement < Self.tapMaxDisplacement {
                        if wasLong {
                            onRightClick?()
                        } else {
                            tapped()
                        }
                    }
                }
        )
        .accessibilityLabel("Relative pointer")
        .accessibilityHint("Drag to nudge the cursor, tap for left click, hold for right click, tap twice to change speed")
    }

    /// The click waits for the double-tap window, the cost of both gestures on one control: otherwise every attempt to change the speed would also click under the pointer. A hold is no part of a double tap, so right-click fires at once.
    private func tapped() {
        let now = Date()
        if let last = lastTapEndedAt, now.timeIntervalSince(last) < Self.doubleTapWindow {
            pendingClick?.cancel()
            pendingClick = nil
            lastTapEndedAt = nil
            onDoubleTap?()
            return
        }

        lastTapEndedAt = now
        pendingClick?.cancel()
        pendingClick = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
            guard !Task.isCancelled else { return }
            onTap?()
            lastTapEndedAt = nil
        }
    }

    /// Was 30: the host cannot post a step it has not been sent, so the pointer moved in thirty jumps a second beside sixty-fps video. Doubling it costs about thirty more small messages a second.
    private static let sendHz: TimeInterval = 1.0 / 60

    /// The delta is proportional to the time since the previous sample, so speed is independent of touch rate and a dropped sample costs a longer step.
    private func emit(_ offset: CGSize) {
        let now = Date()
        let interval = lastSample.map { min(now.timeIntervalSince($0), Self.maximumSampleGap) } ?? 0
        lastSample = now
        guard interval > 0 else { return }

        let dx = Double(offset.width / radius) * Self.travelPerSecond * pointSize.width * interval
        let dy = Double(offset.height / radius) * Self.travelPerSecond * pointSize.height * interval
        guard dx.isFinite, dy.isFinite else { return }

        pendingDx += dx
        pendingDy += dy
    }

    /// Drains on its own clock, not on touch samples: sending inside `emit` behind a one-sixtieth-second gate cannot work because samples arrive at about sixty a second, so jitter refused one and burst the next carrying double, which read as choppy motion. A timer's jitter is a millisecond or two against the sixteen the samples fought over.
    private func startDraining() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sendHz))
                flush()
            }
        }
    }

    /// Sends whatever is left: a delta accumulated after the gate closed was only sent if another sample arrived, so letting go mid-flick left the pointer short.
    private func stopDraining() {
        drainTask?.cancel()
        drainTask = nil
        flush()
    }

    private func flush() {
        guard pendingDx != 0 || pendingDy != 0 else { return }
        let toSend = CGSize(width: pendingDx, height: pendingDy)
        pendingDx = 0
        pendingDy = 0
        onMove(toSend)
    }
}

/// Split out because a `Menu` in a rail takes a label rather than a button; one view means the two cannot disagree.
struct RailButtonLabel: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var enabled: Bool = true

    @Environment(\.controlIsPressed) private var isPressed: Bool

    private static let minimumWidth: CGFloat = ChromeMetrics.panelWidth - 8

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? ColorPalette.ink : (enabled ? Color.primary : Color.secondary))
            Text(label)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? ColorPalette.ink : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity)
        .frame(height: ChromeMetrics.buttonHeight)
        // A stadium like the rail it sits in: the rail's ends and the button's ends are the only two curves on screen and must match.
        .background {
            // The press is drawn over the state so a selected control flashes without losing the blue that says it is on.
            Capsule()
                .fill(selected ? ColorPalette.selectedFill : Color.clear)
                .overlay { Capsule().fill(isPressed ? ColorPalette.pressedFill : Color.clear) }
        }
        .animation(Motion.tap, value: selected)
        .animation(Motion.tap, value: enabled)
    }
}

/// Return is the most pressed key on a remote desktop, so it sits under the hand holding the phone.
struct QuickKeyButton: View {
    let icon: String
    let label: String
    var size: CGFloat = ChromeMetrics.quickKeySize
    /// The return arrow and back chevron are both small glass discs in one corner, so a word tells them apart; `label` stays as the spoken name.
    var caption: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: size / 3, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: size, height: size)
                .glassSurface(in: Capsule(), interactive: true)
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .accessibilityLabel(label)
    }
}

/// Published by ``RailButtonStyle``, the only thing that sees a press, and read by the label, which knows its own shape.
private struct ControlPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var controlIsPressed: Bool {
        get { self[ControlPressedKey.self] }
        set { self[ControlPressedKey.self] = newValue }
    }
}

/// A `.plain` button on iOS shows no sign it was hit, which on a translucent panel over live video makes a tap feel dead.
struct RailButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    /// Off by default: elsewhere a tap is answered by a visible change and buzzing is noise. The session chrome turns it on because its work happens on the other machine.
    var haptic: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.controlIsPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in
                haptic && pressed
            }
    }
}

struct RailButton: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RailButtonLabel(icon: icon, label: label, selected: selected, enabled: enabled)
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The chord is the primary mark: shown as the shortcut text it scans faster than a glyph and carries over from the physical keyboard.
struct ShortcutRailButton: View {
    let chord: String
    let label: String
    let accessibilityLabel: String
    var action: () -> Void

    @Environment(\.controlIsPressed) private var isPressed: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(chord)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(minWidth: ChromeMetrics.panelWidth - 8, maxWidth: .infinity)
            .frame(height: ChromeMetrics.buttonHeight)
            .contentShape(Capsule())
            .background(isPressed ? ColorPalette.pressedFill : Color.clear, in: Capsule())
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Sends \(chord) to the Mac")
    }
}

struct ControlRail<Content: View>: View {
    private let content: Content
    private let maxHeight: CGFloat

    init(maxHeight: CGFloat = .infinity, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        // Ordered most-used first: anything the user has to scroll to is by definition not what they reach for most.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: ChromeMetrics.buttonGap) {
                content
            }
            .padding(.vertical, ChromeMetrics.railPadding)
            .padding(.horizontal, ChromeMetrics.railSidePadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: ChromeMetrics.panelWidth)
        .frame(maxHeight: maxHeight)
        // A stadium, not a rounded rectangle: at this width a 20pt radius reads as neither pill nor rectangle, and the rail is the only panel taller than wide. Other panels keep `cornerRadius`.
        .glassSurface(in: Capsule())
        // Clipped to the same capsule: `glassSurface(in:)` only shapes the background, so content scrolling past a short rail's end shows through the transparent curve.
        .clipShape(Capsule())
    }
}

/// A wheel with detents, replacing a slider that asked the user to position something against a range this control does not have, sent a raw fraction of finger travel (a shaky drag scrolled further than a steady one) and gave no countable step.
/// A notch is a fixed amount of finger travel (``ScrollNotch/travel``) and of document (``ScrollNotch/pixels``), felt as a tap and seen as one ridge. The arrows roll exactly one notch. The two-finger gesture stays the smooth, trackpad-style shortcut.
struct ScrollWheelView: View {
    /// Positive scrolls down, matching the two-finger drag on the picture.
    var onNotch: (Int) -> Void

    /// Only spoken: the same control scrolls the Mac or resizes the picture depending on mode, so its accessibility name must follow.
    var label: String = String(localized: "Scroll the Mac")

    /// Nil when the wheel has no value to show: scrolling the Mac has no position to report, so the rim turns. Set, the control becomes a gauge and the rim is replaced by a fill.
    var position: CGFloat?

    /// One ridge to a notch, so the rim is the count.
    private static let ridgeSpacing: CGFloat = 9

    private static let rimWidth: CGFloat = 14

    private static let spinHz: TimeInterval = 1.0 / 60

    private static let detentInterval: TimeInterval = 0.05

    /// A third of each sample: one sample is a noisy speed estimate (a single long frame reads as a fast flick). This gives about a 50 ms time constant and errs low, which costs only a shorter coast.
    private static let velocitySmoothing: Double = 0.35

    /// A longer gap is a stopped finger, not a slow one: no samples arrive while it rests, so flick, hold, lift would otherwise coast on the old speed.
    private static let restGap: TimeInterval = 0.06

    @State private var wheel = ScrollWheelState()
    /// Nil between gestures, which tells the first sample of a drag (a position but no travel) from the rest.
    @State private var lastY: CGFloat?
    @State private var lastSampleAt: Date?
    @State private var velocity: Double = 0
    @State private var spinTask: Task<Void, Never>?
    @State private var lastDetentAt: Date?
    /// A counter of its own rather than the notch count: a coast fires many detents for one roll call, and the haptic trigger counts feedback.
    @State private var detents = 0

    /// Whether this is a wheel or a gauge is whether it has a ``position``. A gauge must not coast (it would run past its own end) nor be spoken about in notches.
    private var isGauge: Bool { position != nil }

    var body: some View {
        VStack(spacing: ChromeMetrics.buttonGap) {
            chevron("chevron.up", notch: -1)
            rim
            chevron("chevron.down", notch: 1)
        }
        .padding(.vertical, ChromeMetrics.panelPadding)
        .frame(width: ChromeMetrics.panelWidth, height: ChromeMetrics.wheelHeight)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous))
        // The detent: a tick in the hand as the notch goes out, so the count is available without looking.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: detents)
        // A coasting wheel must be caught when its control leaves the screen (rotating to portrait), or the Mac keeps scrolling with nothing on screen to stop it.
        .onDisappear { stopSpin() }
        // Also caught when the mode changes: the rest of a flick would otherwise be spent as zoom steps nobody asked for.
        .onChange(of: isGauge) { stopSpin() }
    }

    /// The whole band is the drag target, not the rim: fourteen points is not reliably findable by a thumb held one-handed.
    private var rim: some View {
        ZStack {
            if let position {
                gauge(position)
            } else {
                ridges
                indexMark
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
        .accessibilityLabel(label)
        .accessibilityHint(
            isGauge
                ? "Drag to zoom one step at a time"
                : "Drag to roll the wheel a line at a time, flick to keep it rolling"
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(-1)
            case .decrement: step(1)
            @unknown default: break
            }
        }
    }

    /// A `Canvas`, since the ridges move on every drag sample and a dozen views would cost a dozen layout passes per frame.
    private var ridges: some View {
        Canvas { context, size in
            // The pattern wraps so the rim has no end: a surface that ran out would be clamped, and a clamped control is the slider again. The cost is that seven whole notches in one gesture look like none from the drawing alone.
            let spacing = Self.ridgeSpacing
            let offset = CGFloat(wheel.phase.truncatingRemainder(dividingBy: 1)) * spacing
            var y = offset
            while y < size.height {
                context.fill(
                    Path(roundedRect: CGRect(x: 1.5, y: y, width: size.width - 3, height: 1),
                         cornerRadius: 0.5),
                    with: .color(ColorPalette.ink.opacity(0.5))
                )
                y += spacing
            }
        }
        .frame(width: Self.rimWidth)
        .frame(maxHeight: .infinity)
        .background(ColorPalette.surface, in: Capsule())
        .clipShape(Capsule())
    }

    /// Fixed, with the rim moving past it, so the eye can count ridges. White rather than the accent, which the palette keeps for selection and the one gauge fill: an index mark is a measurement.
    private var indexMark: some View {
        Capsule()
            .fill(ColorPalette.ink)
            .frame(width: Self.rimWidth + 10, height: 2)
            // The rim crosses a bright window and a black one, and a two-point white line needs help on the first. The joystick's knob is shadowed for the same reason.
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
    }

    /// A fill rising from the bottom is the one shape that reads as this much out of that much without being learned; the old handle that sprang back reported nothing.
    private func gauge(_ position: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(ColorPalette.surface)
                    .frame(width: Self.rimWidth)

                Capsule()
                    .fill(ColorPalette.accent)
                    .frame(width: Self.rimWidth, height: max(Self.rimWidth, proxy.size.height * position))
                    .animation(Motion.tap, value: position)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// Relative travel (this sample less the last), not the finger's place on the panel: the panel is 120 points tall and a document is not, so a place-to-place mapping (what the slider did) means nothing.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A touch catches the wheel dead rather than handing the coast to the finger's speed, which would put part of a flick's distance in the arithmetic and part in the thumb.
                stopSpin()

                let travel = value.location.y - (lastY ?? value.location.y)
                lastY = value.location.y
                sample(travel, at: value.time)
                emit(wheel.roll(points: Double(travel)), spinning: false)
            }
            .onEnded { value in
                let speed = launchSpeed(at: value.time)
                lastY = nil
                lastSampleAt = nil
                velocity = 0
                // Spring first, then coast: the wheel seats in its nearest notch, so a flick starts from a detent like a real one.
                emit(wheel.seat(), spinning: false)
                startSpin(launch: WheelSpin.launch(pointsPerSecond: speed))
            }
    }

    private func sample(_ travel: CGFloat, at time: Date) {
        guard let previous = lastSampleAt else {
            lastSampleAt = time
            velocity = 0
            return
        }
        let interval = time.timeIntervalSince(previous)
        lastSampleAt = time
        // A pause is not a slow sample: dividing one would turn a stopped finger into a speed.
        guard interval > 0, interval < Self.restGap else {
            velocity = 0
            return
        }
        velocity += (Double(travel) / interval - velocity) * Self.velocitySmoothing
    }

    private func launchSpeed(at lift: Date) -> Double {
        guard let last = lastSampleAt, lift.timeIntervalSince(last) < Self.restGap else { return 0 }
        return velocity
    }

    /// A gauge does not coast (see ``isGauge``), nor does a placed-and-lifted or slowly dragged finger: the wheel must exceed ``WheelSpin/stalling``, so a careful drag does not end in a lurch.
    private func startSpin(launch: Double) {
        guard !isGauge, launch > WheelSpin.stalling else { return }
        spinTask?.cancel()

        let started = Date()
        let duration = WheelSpin.duration(launch)
        spinTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.spinHz))
                // A cancelled sleep returns at once, and without this the loop would emit one more
                // roll after the wheel had been caught.
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                guard elapsed < duration else { return }
                emit(wheel.roll(notches: WheelSpin.rate(launch, after: elapsed) * Self.spinHz),
                     spinning: true)
            }
        }
    }

    private func stopSpin() {
        spinTask?.cancel()
        spinTask = nil
    }

    /// One notch, from an arrow or VoiceOver: the finest step, no aim needed. A tap during a coast finishes the notch it was in, then adds its own.
    private func step(_ notch: Int) {
        stopSpin()
        emit(wheel.seat(), spinning: false)
        emit(wheel.roll(notches: Double(notch)), spinning: false)
    }

    private func emit(_ notches: Int, spinning: Bool) {
        guard notches != 0 else { return }
        onNotch(notches)
        detent(spinning: spinning)
    }

    /// Rate-limited while coasting: at the cap this asks for 120 impacts a second and the Taptic Engine saturates into one continuous buzz. Twenty a second reads as the rattle of a spinning-down wheel.
    private func detent(spinning: Bool) {
        let now = Date()
        if spinning, let last = lastDetentAt, now.timeIntervalSince(last) < Self.detentInterval {
            return
        }
        lastDetentAt = now
        detents += 1
    }

    private func chevron(_ symbol: String, notch: Int) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { step(notch) }
    }
}

/// Latching, not momentary: a touch screen cannot hold the modifier with one hand and type with the other. Each button posts a real modifier press and release; see ``SessionModel/toggleModifier(_:keyCode:)`` for why flag bits on the next keystroke are not equivalent.
struct ModifierBar: View {
    @Environment(SessionModel.self) private var model
    var large = false

    /// Left-hand virtual keycodes: the protocol collapses left and right into one bit, so the Mac cannot observe which side is pressed.
    private static let keys: [(title: String, bit: Modifiers, code: UInt16)] = [
        ("⌘", .command, 55),
        ("⇧", .shift, 56),
        ("⌥", .option, 58),
        ("⌃", .control, 59),
    ]

    var body: some View {
        HStack(spacing: large ? 8 : 6) {
            ForEach(Self.keys, id: \.title) { key in
                let isOn = model.latchedModifiers.contains(key.bit)
                Button {
                    model.toggleModifier(key.bit, keyCode: key.code)
                } label: {
                    Text(key.title)
                        .font(.system(size: 17, weight: .medium))
                        .frame(minWidth: large ? nil : 28, idealWidth: large ? nil : 38, maxWidth: large ? nil : 38, minHeight: large ? 44 : 34, maxHeight: large ? 44 : 34)
                        .frame(maxWidth: large ? .infinity : nil)
                        .foregroundStyle(isOn ? ColorPalette.ink : Color.primary)
                        .background(isOn ? ColorPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .glassSurface(in: RoundedRectangle(cornerRadius: 9, style: .continuous), interactive: true)
                }
                .buttonStyle(RailButtonStyle(scale: 0.86))
                .accessibilityLabel(key.title)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

struct MacroBar: View {
    @Environment(SessionModel.self) private var model
    @State private var showingMacroEditor = false

    var body: some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
                ForEach(model.allMacros) { macro in
                    Button {
                        model.run(macro)
                    } label: {
                        Text(macro.title)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 8)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                }

                // What is paid is making a macro, not using one: the built-in chips are the keyboard and free on every plan, and gating them would charge for the keyboard. On a plan without the editor the button stays, dimmed with the badge, so users can see what it does.
                PlanLocked(capability: .macros, title: String(localized: "Edit macros"), diameter: 34) {
                    Button {
                        showingMacroEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .medium))
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                    .accessibilityLabel("Edit macros")
                }
        }
        .sheet(isPresented: $showingMacroEditor) {
            MacroEditorView(model: model)
        }
    }
}

/// Shared by the source list and the settings panel. One shape at two sizes: every number is a ratio of `size` (the shipped 42-point value over 42), so the picker's 60-point grid keeps the same corner and padding.
struct ApplicationIcon: View {
    let data: Data?
    let fallback: String

    var size: CGFloat = 42

    private var corner: CGFloat { size * (11.0 / 42.0) }

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * (20.0 / 42.0), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(size * (8.0 / 42.0))
            }
        }
        .frame(width: size, height: size)
        .background(
            .white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: corner, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

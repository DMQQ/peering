import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// A relative pointer control.
///
/// The canvas moves the cursor to where a finger touches, which is the right model for
/// pointing at something specific and the wrong one for the small corrections that make up
/// most of using a computer: reaching a menu bar, nudging a slider, getting back to a button
/// the finger is covering. A joystick does those, because it is relative.
///
/// The deltas are computed per unit **time**, not per touch sample. A trackpad-style
/// per-sample delta would double the cursor speed on a 120 Hz display relative to a 60 Hz
/// one, which is a bug that only shows up on some hardware.
struct JoystickView: View {
    /// Called with the travel for this sample, in the Mac's display points.
    var onMove: (CGSize) -> Void
    /// Fired on a short tap — sends a left click at the current cursor position.
    var onTap: (() -> Void)?
    /// Fired when a long-press (≥ 450 ms with little movement) is released — sends a right click.
    var onRightClick: (() -> Void)?
    /// Fired on a second tap inside the double-tap window — the host's own control, not a Mac
    /// gesture: this is where the pointer's speed is stepped through.
    var onDoubleTap: (() -> Void)?
    /// Shown in the middle of the pad while it is worth saying, which is just after a speed
    /// change. The joystick is under a thumb and has no room for a caption, so the feedback for
    /// a gesture has to be on the thing the gesture was made on.
    var speedText: String?
    var pointSize: CGSize
    var radius: CGFloat = 54

    /// Fraction of the captured surface travelled per second at full deflection.
    private static let travelPerSecond = 1.5
    /// A gap longer than this is a new gesture, not a slow one — otherwise the first sample
    /// of a new drag carries all the time since the last one and the cursor jumps.
    private static let maximumSampleGap: TimeInterval = 0.05
    private static let longPressDuration: TimeInterval = 0.45
    private static let tapMaxDisplacement: CGFloat = 8
    /// How long a tap waits to find out whether it was the first of two. iOS uses the same
    /// figure for its own double-tap gestures, so it is a delay the hand is already trained on.
    private static let doubleTapWindow: TimeInterval = 0.3

    @State private var knob: CGSize = .zero
    @State private var lastSample: Date?
    @State private var touchStart: Date?
    @State private var isLongPress = false
    @State private var holdTask: Task<Void, Never>?
    /// When the last tap finished, and the click that is waiting to see whether a second one
    /// arrives — see ``tapped()``.
    @State private var lastTapEndedAt: Date?
    @State private var pendingClick: Task<Void, Never>?
    /// Movement waiting to be sent, and the clock that sends it. See ``startDraining()``.
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
                // The right-click state is a ring that blooms out of the knob rather than a
                // change of colour: it reads on any background the Mac happens to be showing,
                // and it says "held" in a way a hue never did.
                .overlay {
                    Circle()
                        .strokeBorder(ColorPalette.ink, lineWidth: 2)
                        .scaleEffect(isLongPress ? 1.4 : 1)
                        .opacity(isLongPress ? 1 : 0)
                }
                .offset(knob)
                .shadow(radius: 3)
                // Deliberately *not* animated on `knob`. It is set on every sample of a drag, so
                // this was starting a spring a hundred-odd times a second on the main thread —
                // for a view whose whole job is to be under the finger, where anything but
                // following it exactly is a lag the user can feel. The return to centre is
                // animated at the one moment it happens, in `onEnded`.
                .animation(Motion.tap, value: isLongPress)

            // On its own capsule so it reads over the knob, over the glass, and over a picture
            // bright enough to make the glass disappear.
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
                    // Cancel the long-press timer the moment the finger has moved enough to
                    // be a drag — otherwise a slow short drag triggers right-click on release.
                    if hypot(raw.width, raw.height) > Self.tapMaxDisplacement {
                        holdTask?.cancel()
                        holdTask = nil
                        isLongPress = false
                    }
                    // Clamped to the ring, so a finger that wanders off the pad keeps pushing
                    // at full deflection instead of reporting a magnitude the Mac would scale
                    // into an implausibly large jump.
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
                    // The one animation the knob gets: it springs back to the middle rather than
                    // snapping there, which is what says the stick is at rest.
                    withAnimation(Motion.settle) { knob = .zero }
                    lastSample = nil
                    touchStart = nil
                    isLongPress = false

                    let displacement = hypot(value.translation.width, value.translation.height)
                    if displacement < Self.tapMaxDisplacement {
                        if wasLong {
                            // A hold cannot be the first half of a double tap, so this one needs
                            // no waiting.
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

    /// Resolves a tap into either a click or half of a double tap.
    ///
    /// The click waits for the double-tap window, and that delay is the whole cost of having
    /// both gestures on one control. It is worth paying here: the alternative is the click going
    /// out on the first tap regardless, so every attempt to change the speed would also click
    /// whatever the Mac's pointer happened to be resting on — and a click you did not ask for is
    /// not a small mistake on a desktop.
    ///
    /// A hold is not part of a double tap, so right-click fires immediately as it always did.
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

    /// How often the accumulator is drained, and so how often the Mac is told the pointer moved.
    ///
    /// This was 30 once, and doubling it fixed half the cursor's smoothness: the host cannot
    /// post a step it has not been sent, so the pointer moved in thirty discrete jumps a second
    /// while the video beside it resolved sixty. The cost of the other half is about thirty more
    /// messages a second at roughly forty bytes each, against a video stream measured in
    /// megabits.
    private static let sendHz: TimeInterval = 1.0 / 60

    /// Accumulates one sample of movement. Sending is somebody else's job — see ``startDraining()``.
    ///
    /// The delta is proportional to the time since the previous sample, so the pointer covers
    /// the same ground per second whatever rate the touches happen to arrive at, and a dropped
    /// sample costs a slightly longer step rather than a shorter one.
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

    /// Drains the accumulator on a clock of its own, rather than on the touch samples.
    ///
    /// **This is the whole of why the pointer is smooth or not.** Sending used to happen inside
    /// `emit`, behind a gate that asked "has it been a sixtieth of a second since the last
    /// send?" — and it cannot be, because the samples arrive at about sixty a second
    /// themselves. Jitter means one sample is refused and the next bursts through carrying
    /// twice the movement, so the Mac was told about the pointer in thirty irregular jumps a
    /// second instead of sixty even ones. Nothing was lost; the motion simply read as choppy.
    ///
    /// It also explains the thing that made this worth chasing: moving the Mac's own mouse
    /// looks better than driving it from here. The hardware feeds the cursor at its own rate
    /// and has nothing to alias with. A timer's jitter is a millisecond or two, against the
    /// sixteen the samples were fighting over.
    private func startDraining() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sendHz))
                flush()
            }
        }
    }

    /// Stops the clock and sends whatever is left, so the last of a movement is not stranded.
    ///
    /// That stranding is the other half of the old bug: a delta accumulated after the gate
    /// closed was only ever sent if another sample happened to arrive, so letting go of the
    /// stick mid-flick dropped the final step and left the pointer a little short of where the
    /// finger went.
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

/// The visual half of a rail button.
///
/// Split out because the `Menu`s that sit in a rail take a label rather than a button as their
/// content, and a menu that did not match the buttons beside it would read as a different kind
/// of control. Built from one view, the two cannot disagree.
struct RailButtonLabel: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var enabled: Bool = true

    @Environment(\.controlIsPressed) private var isPressed: Bool

    /// Narrow enough that the rail does not eat into the picture, wide enough that the caption
    /// stays legible — the label shrinks before the rail grows.
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
        // A stadium, like the rail it sits in. A 10pt corner inside a capsule is a shape borrowed
        // from somewhere else: the rail's ends and the button's ends are the only two curves on
        // screen and they have to be the same curve. In the rail, where a button is as wide as it
        // is tall, this makes it a circle.
        .background {
            // The press is drawn over the state rather than in its place, so a selected control
            // flashes with the rest of the bar instead of losing the blue that says it is on.
            Capsule()
                .fill(selected ? ColorPalette.selectedFill : Color.clear)
                .overlay { Capsule().fill(isPressed ? ColorPalette.pressedFill : Color.clear) }
        }
        // On the label, so the icon, the caption and the fill all move as one thing.
        .animation(Motion.tap, value: selected)
        .animation(Motion.tap, value: enabled)
    }
}

/// A single key, sized for a thumb rather than for a rail.
///
/// Return is the key that gets pressed more than any other on a remote desktop — it is how a
/// dialogue is dismissed, a search is run and a field is committed — and it was living in the
/// shortcuts panel behind a toggle. A key that common belongs under the hand that is already
/// holding the phone.
struct QuickKeyButton: View {
    let icon: String
    let label: String
    var size: CGFloat = ChromeMetrics.quickKeySize
    /// A word under the glyph, for a key whose symbol is not the whole of what it does.
    ///
    /// The return arrow and the back chevron are both small, both in the same corner, and both
    /// glass discs with nothing else on them — close enough that they are told apart by position
    /// and memory rather than by looking. `label` stays as the spoken name; this is the same word
    /// made visible.
    var caption: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    // Proportional to the button, so a smaller one is a smaller button rather
                    // than a small button with a full-size glyph in it. At the default size this
                    // is the 20 it has always been.
                    .font(.system(size: size / 3, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: size, height: size)
                // Round, like every other standalone control here. A key beside the pointer is the
                // same kind of object as the joystick next to it, not the same kind as a rail
                // button that happens to be alone.
                .glassSurface(in: Capsule(), interactive: true)
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .accessibilityLabel(label)
    }
}

/// Whether the control a label is drawn in is under a finger at this moment.
///
/// Published by ``RailButtonStyle``, because the style is the only thing that can see a press, and
/// read by the label, because the shape a press lights up in is the label's to know. Handed the
/// shape instead, the style would need to be told it by every control that uses it.
private struct ControlPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var controlIsPressed: Bool {
        get { self[ControlPressedKey.self] }
        set { self[ControlPressedKey.self] = newValue }
    }
}

/// The press feedback every control in a rail shares.
///
/// A `.plain` button on iOS gives no sign it was hit at all, which on a translucent panel over
/// live video makes a tap feel like it did nothing. That is the worst outcome for a control whose
/// whole job is sending an event to another machine, where the result cannot be seen from here.
struct RailButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    /// Whether the press is felt as well as seen.
    ///
    /// Off by default. Everywhere else in the app a tap is answered by a sheet, a row or a screen
    /// appearing, and buzzing on top of that is noise. The session chrome turns it on, because its
    /// controls are the ones whose work happens on the other machine: they answer here or nowhere.
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

/// One button in a control rail or the portrait bar.
///
/// Icon over a short caption, which is the shape the portrait dock already used: the landscape
/// rail is the same control stacked rather than scrolled, so there is one button to change
/// instead of two that drift apart. The caption is not decoration — it is the only thing on
/// screen that says what an icon does.
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

/// A keyboard chord in the landscape quick-actions rail.
///
/// The chord is the primary mark rather than an icon. Showing `⌘C` is faster to scan than a
/// document glyph with a caption, and it teaches the same muscle memory the physical keyboard
/// uses without inventing another symbol language for standard Mac shortcuts.
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
            // A chord in this rail sends a key and shows nothing for it, which is the same case
            // the dock's controls are in and gets the same flash.
            .background(isPressed ? ColorPalette.pressedFill : Color.clear, in: Capsule())
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Sends \(chord) to the Mac")
    }
}

/// A group of buttons in one container.
///
/// The container is the point. Nine separate buttons in four shapes read as clutter wherever
/// they are put; what makes a rail legible is that the panel behind them says these belong
/// together and nothing else does.
struct ControlRail<Content: View>: View {
    private let content: Content
    /// The tallest the rail may grow before its buttons scroll instead of overflowing.
    private let maxHeight: CGFloat

    init(maxHeight: CGFloat = .infinity, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        // Scrollable because a rail is the one place on this screen with room to grow: the
        // buttons run down the edge in the order they are reached for, and the ones below the
        // fold cost nothing until they are wanted. Ordered most-used first, for that reason —
        // anything the user has to scroll to find is by definition not what they reach for most.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: ChromeMetrics.buttonGap) {
                content
            }
            .padding(.vertical, ChromeMetrics.railPadding)
            .padding(.horizontal, ChromeMetrics.railSidePadding)
        }
        // No rubber-banding when the buttons already fit, which is most of the time: a rail that
        // jiggles under a finger when there is nothing to scroll reads as a loose control.
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: ChromeMetrics.panelWidth)
        .frame(maxHeight: maxHeight)
        // A stadium, not a rounded rectangle. At this width a 20pt radius is two thirds of the
        // half-width, which is the one proportion that reads as neither — too round to be a
        // rectangle, too square to be a pill — and the rail is the only panel here that is taller
        // than it is wide, so it is the only one where that shows. The other panels keep
        // `cornerRadius`: they are wider than they are tall, and a semicircular end would eat
        // their content rather than frame it.
        .glassSurface(in: Capsule())
        // Clipped to that same capsule, and this is not the same thing as shaping the glass.
        // `glassSurface(in:)` only draws the background in a capsule; the content is still bounded
        // by the rail's *rectangle*, so a button scrolling past the end of a short rail shows
        // through the transparent curve beside it and the caption appears to float outside its own
        // panel. The padding above keeps buttons clear of the curve at rest; this is what keeps
        // them clear while they move through it.
        .clipShape(Capsule())
    }
}

/// A wheel you roll with a thumb.
///
/// It was a slider before — a track with a knob that followed the drag and sprang back to the
/// middle when it was let go — and that shape was the imprecision, in three separate ways.
///
/// It asked the user to *position* something, and a position only means anything against a range.
/// This control has no range: it does not know where the Mac's document is or how long it is, so
/// the knob reported the drag rather than the scroll, and where it came to rest said nothing about
/// what had happened on the other machine.
///
/// It sent a raw fraction of the finger's movement, six pixels to the point, so the amount scrolled
/// was whatever the hand produced — a shaky drag scrolled further than a steady one — and there
/// was no way to ask for one line, because a line was under two points of travel.
///
/// And it had no steps. Nothing in the feel of it said "that was one notch", so there was nothing
/// to count, nothing to aim with, and no way to tell a small scroll that had happened from a small
/// scroll that had not.
///
/// A wheel answers all three with the one thing a slider cannot have, which is a detent. A notch
/// here is a fixed amount of finger travel (``ScrollNotch/travel``) and a fixed amount of document
/// (``ScrollNotch/pixels``); it is felt as a tap in the hand, seen as one ridge passing the mark,
/// and it can be counted. A drag is a number of notches rather than a distance. A flick keeps the
/// wheel turning for a distance that is known in advance, and a touch catches it. The arrows above
/// and below roll exactly one notch each, which is the finest step the control has and needs no aim
/// at all — the thumb does not have to find the wheel to be precise with the Mac.
///
/// The two-finger gesture is still the shortcut, and still the only smooth one: it takes the second
/// hand off the phone and cannot be done one-handed at all, which is how a phone is usually held,
/// but it is a trackpad and this is a wheel, and a wheel is notched because that is what makes it
/// countable. Both live on the same screen and either is right for what it is.
struct ScrollWheelView: View {
    /// Whole notches, signed the way a wheel rolled towards the user reads: positive scrolls down,
    /// which is the direction the two-finger drag on the picture already reports.
    var onNotch: (Int) -> Void

    /// What this wheel does at the moment — scrolling the Mac or resizing the picture. Only ever
    /// spoken, and only because the same control means two different things depending on the mode
    /// the user chose: a control whose name is fixed while its job is not is a control that lies
    /// to whoever is listening rather than looking.
    var label: String = "Scroll the Mac"

    /// Where this control's value sits, 0 at the bottom of the track and 1 at the top.
    ///
    /// Nil when the wheel has no value to show — scrolling the Mac has no position to report, so
    /// the rim turns instead and the Mac is told about notches. Set, the control becomes a gauge
    /// and the rim is replaced by a fill up to this point.
    var position: CGFloat?

    /// Points between one ridge and the next on the rim.
    ///
    /// One ridge to a notch, deliberately: the rim *is* the count. Someone who has watched three
    /// ridges go past the mark has scrolled three lines and can say so without looking away from
    /// the Mac to check.
    private static let ridgeSpacing: CGFloat = 9

    /// The width of the rim itself.
    ///
    /// Wider than the ten-point track it replaces, because it is now the whole of what the control
    /// looks like rather than a groove for a knob to slide in.
    private static let rimWidth: CGFloat = 14

    /// How often a coasting wheel is advanced. Sixty times a second, like everything else here.
    private static let spinHz: TimeInterval = 1.0 / 60

    /// The shortest gap between two detents while the wheel is coasting. See ``detent(spinning:)``.
    private static let detentInterval: TimeInterval = 0.05

    /// How much of each sample's velocity is taken into the running estimate.
    ///
    /// The speed of the finger as it leaves is what launches the wheel, and one sample of a drag is
    /// a noisy way to measure it: a single long frame reads as a fast flick. A third of each new
    /// sample gives an estimate with a time constant of about fifty milliseconds — longer than a
    /// frame, shorter than a flick. It errs low if anything, because a finger still accelerating as
    /// it lifts gets only part of its true speed, and erring low costs a shorter coast, which is
    /// the direction to be wrong in.
    private static let velocitySmoothing: Double = 0.35

    /// A gap longer than this between two samples is a stopped finger, not a slow one.
    ///
    /// No samples arrive while a finger rests, so a drag that ended in a pause would otherwise
    /// carry the speed it had before the pause into the coast: flick, hold still, lift, and the
    /// Mac runs on without the hand having asked for it. A finger that stopped meant to stop.
    private static let restGap: TimeInterval = 0.06

    @State private var wheel = ScrollWheelState()
    /// The last position sampled, in the panel's coordinates. Nil between gestures, which is how
    /// the first sample of a drag is told apart from the rest: it has a position but no travel.
    @State private var lastY: CGFloat?
    @State private var lastSampleAt: Date?
    @State private var velocity: Double = 0
    @State private var spinTask: Task<Void, Never>?
    @State private var lastDetentAt: Date?
    /// Incremented once per detent, and the trigger the haptic hangs off.
    ///
    /// A counter of its own rather than the notch count, because it is the *feedback* being
    /// counted: a coast fires many detents for the notches of a single roll call, and a haptic
    /// modifier keyed to `delivered` would have to be told which of them deserved one.
    @State private var detents = 0

    /// Whether this control is a wheel or a gauge, which is exactly whether it has a value to
    /// report — ``position``.
    ///
    /// Nothing else is asked and nothing else needs to be. A control that shows a position must
    /// not coast, because it would run on past its own end while the picture it describes stopped
    /// moving, and it must not be spoken about in notches, because a notch is not what it is
    /// showing. One flag, two consequences, both true by construction.
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
        // The detent, which is the whole of what a wheel has that a slider does not: a tick in the
        // hand at the moment the notch goes out, so the count is available without looking, and —
        // the part that matters for precision — so that a scroll the hand made is a scroll the
        // hand *knows* it made.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: detents)
        // A wheel still coasting when its control leaves the screen has to be caught. Rotating to
        // portrait is how that happens — the wheel is landscape's — and without this the Mac would
        // go on scrolling with nothing on screen to say why, or to stop it.
        .onDisappear { stopSpin() }
        // And it is caught when what a notch *means* changes, which is a switch of mode: the rest
        // of a flick would otherwise be spent as zoom steps nobody asked for, under a drawing that
        // had turned into a gauge while the wheel was still turning.
        .onChange(of: isGauge) { stopSpin() }
    }

    /// The rim, and the mark the ridges turn past.
    ///
    /// The whole band is the drag target rather than the rim itself: fourteen points is not
    /// something a thumb can reliably find while holding a phone one-handed, which is the reason
    /// the old track's whole panel was one too. What changed is the drawing, not the target.
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

    /// The ridges, which are the notches, drawn rather than laid out.
    ///
    /// A `Canvas` because they move on every sample of a drag: a dozen views whose offsets were
    /// rewritten sixty times a second would be a dozen layout passes per frame for what is a dozen
    /// one-point lines.
    private var ridges: some View {
        Canvas { context, size in
            // One ridge to a notch, and the pattern wraps, so the rim has no end. An endless
            // surface is what makes this a wheel rather than the strip of track it used to be: a
            // surface that ran out would have to be clamped somewhere, and a clamped control is
            // the slider again. Wrapping costs the one thing a wheel also costs — seven whole
            // notches in one gesture look like none from the drawing alone — and buys the same
            // thing a wheel does: the surface never stops, so the hand can roll as far as it likes.
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

    /// The mark the ridges are counted against.
    ///
    /// Fixed, with the rim moving past it — the other way round from the knob, which was the thing
    /// that moved. A reference that stays put is what lets the eye count ridges without first
    /// working out where they started, and counting them is the point.
    ///
    /// White rather than the accent, which the palette keeps for selection and for the one gauge
    /// fill on this screen: an index mark is a measurement, and everything that is not a hue here
    /// is brightness. Full-strength ink against half-strength ridges says "reference" without
    /// spending the colour that means "this one is on".
    private var indexMark: some View {
        Capsule()
            .fill(ColorPalette.ink)
            .frame(width: Self.rimWidth + 10, height: 2)
            // The rim crosses a bright window and a black one, and a two-point line of white needs
            // help on the first. The joystick's knob is shadowed for the same reason.
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
    }

    /// The rim as a gauge: a fill rising from the bottom, for the one job this control has that
    /// comes with a value — how much of the zoom range lies below and how much above.
    ///
    /// A handle that sprang back to the middle reported nothing at all, which is exactly what made
    /// it confusing. A fill rising from the bottom is the one shape that reads as "this much, out
    /// of that much" without having to be learned.
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

    /// Rolling the wheel with a finger on it.
    ///
    /// The travel is relative — this sample's position less the last one's — rather than read from
    /// where the finger is on the panel. A wheel turns by how far it is rolled and its resting
    /// position is not a value: the panel is a hundred and twenty points tall and a document is
    /// not, so a mapping from a place on the panel to a place in the document would be a mapping
    /// from nothing to nothing. That mapping is what the slider was doing, and it is why where the
    /// knob came to rest never told anyone anything.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A touch catches the wheel. The hand is on it now, so whatever it was doing it
                // stops doing — dead, rather than handing the coast over to the finger's own
                // speed, because a coast that eased into the hand would put part of a flick's
                // distance in the arithmetic and part in the thumb, and the distance is the one
                // thing a flick is supposed to have settled.
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
                // The spring first, then the coast: the wheel seats itself in the notch it is
                // nearest to, and a flick starts from a wheel that is sitting in a detent like a
                // real one rather than from halfway between two.
                emit(wheel.seat(), spinning: false)
                startSpin(launch: WheelSpin.launch(pointsPerSecond: speed))
            }
    }

    /// Feeds one sample into the running velocity estimate. See ``velocitySmoothing``.
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

    /// How fast the finger was moving when it left, in points per second. See ``restGap``.
    private func launchSpeed(at lift: Date) -> Double {
        guard let last = lastSampleAt, lift.timeIntervalSince(last) < Self.restGap else { return 0 }
        return velocity
    }

    /// Starts the wheel coasting, or does nothing if that was not a flick.
    ///
    /// A gauge does not coast — see ``isGauge`` — and neither does a finger that was placed and
    /// lifted, or one that was dragged slowly: the wheel has to be turning faster than
    /// ``WheelSpin/stalling`` before there is anything to coast with, which is what keeps a
    /// careful drag from ending in a lurch.
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

    /// Catches the wheel where it is. See ``drag`` for why it stops dead rather than slowing.
    private func stopSpin() {
        spinTask?.cancel()
        spinTask = nil
    }

    /// One notch, from an arrow or from a VoiceOver adjustment.
    ///
    /// Nothing else about the control delivers less than a whole notch, and this is the one thing
    /// that delivers exactly one: no aim, no travel, no judgement of distance. The finest step
    /// there is, and the one a user reaching for a *small* scroll tries first — which is why it is
    /// a notch rather than the ninety pixels it used to be, nearer four lines and too much to call
    /// precise.
    ///
    /// A tap that arrives while the wheel is still coasting from a flick finishes the notch it was
    /// in first, and then adds its own: that is what a hand grabbing a turning wheel would get.
    private func step(_ notch: Int) {
        stopSpin()
        emit(wheel.seat(), spinning: false)
        emit(wheel.roll(notches: Double(notch)), spinning: false)
    }

    /// Hands over whole notches, and taps the hand once for them.
    private func emit(_ notches: Int, spinning: Bool) {
        guard notches != 0 else { return }
        onNotch(notches)
        detent(spinning: spinning)
    }

    /// The detent: the tap in the hand that says a notch went by.
    ///
    /// Rate-limited while the wheel is coasting, because neither the hand nor the engine can count
    /// at that speed: at the cap this asks for a hundred and twenty impacts a second, and the
    /// Taptic Engine answers a rate like that by saturating into one continuous buzz that says
    /// nothing about how fast the wheel is turning. Twenty a second reads as the rattle of a wheel
    /// spinning down, which is the thing it is imitating.
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

/// The modifier keys, as latching buttons.
///
/// Latching rather than momentary, because a touch screen cannot hold ⌘ with one hand and
/// type with the other. Each button posts a real modifier key press and release — see
/// ``SessionModel/toggleModifier(_:keyCode:)`` for why flag bits on the next keystroke are
/// not equivalent.
struct ModifierBar: View {
    @Environment(SessionModel.self) private var model

    /// Left-hand virtual keycodes. The protocol collapses left and right into one bit, so
    /// which side is pressed cannot be observed by the Mac.
    private static let keys: [(title: String, bit: Modifiers, code: UInt16)] = [
        ("⌘", .command, 55),
        ("⇧", .shift, 56),
        ("⌥", .option, 58),
        ("⌃", .control, 59),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.keys, id: \.title) { key in
                let isOn = model.latchedModifiers.contains(key.bit)
                Button {
                    model.toggleModifier(key.bit, keyCode: key.code)
                } label: {
                    Text(key.title)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 34)
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

/// One-tap shortcuts.
struct MacroBar: View {
    @Environment(SessionModel.self) private var model
    @State private var showingMacroEditor = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.allMacros) { macro in
                    Button {
                        model.run(macro)
                    } label: {
                        Text(macro.title)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                }

                // Macro editor
                Rectangle()
                    .frame(width: 1, height: 22)
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 2)

                // **The line between what is paid here and what is not is making one, not using
                // one.** The chips to the left are the keyboard: ⌘C, esc, ⏎ and the control keys a
                // phone keyboard cannot send, and they are free on every plan along with the rest
                // of the pointer and the keyboard. What Pro adds is the editor behind this button:
                // a macro you save, a snippet you keep, a command you fire instead of typing it.
                // Gating the built-in keys instead would be charging for the keyboard.
                //
                // The button keeps its slider on a plan that does not include the editor, dimmed,
                // with the badge on its corner. The rail is a row of glyphs and this is one of them:
                // taking the glyph away leaves a row that cannot say which of the buttons in it
                // edits macros, and the seller of the feature is the last button that should stop
                // saying what it does.
                PlanLocked(capability: .macros, title: "Edit macros", diameter: 34) {
                    Button {
                        showingMacroEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 34)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                    .accessibilityLabel("Edit macros")
                }
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $showingMacroEditor) {
            MacroEditorView(model: model)
        }
    }
}

/// An application's icon: the PNG the host rendered, or a symbol when it sent none.
///
/// Shared rather than private to the picker, because the source list and the settings panel both
/// draw rows of them.
///
/// **One shape at two sizes, and the numbers are ratios of `size` rather than values.** The rows
/// this was written for draw it at 42; the picker's grid draws it at 60, where the same shape has
/// to keep its corner and its padding or an icon grid is a row that got bigger rather than a
/// different arrangement. Each ratio is the shipped 42-point value divided by 42, so the size it
/// has always been drawn at comes out identical to the point.
struct ApplicationIcon: View {
    let data: Data?
    let fallback: String

    /// Edge length in points, the one number the rest are derived from.
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

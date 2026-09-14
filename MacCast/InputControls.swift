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
    var pointSize: CGSize
    var radius: CGFloat = 54

    /// Fraction of the captured surface travelled per second at full deflection.
    private static let travelPerSecond = 1.5
    /// A gap longer than this is a new gesture, not a slow one — otherwise the first sample
    /// of a new drag carries all the time since the last one and the cursor jumps.
    private static let maximumSampleGap: TimeInterval = 0.05
    private static let longPressDuration: TimeInterval = 0.45
    private static let tapMaxDisplacement: CGFloat = 8

    @State private var knob: CGSize = .zero
    @State private var lastSample: Date?
    @State private var touchStart: Date?
    @State private var isLongPress = false
    @State private var holdTask: Task<Void, Never>?
    // Accumulated delta and last-send timestamp, used to cap the send rate.
    @State private var pendingDx: Double = 0
    @State private var pendingDy: Double = 0
    @State private var lastEmit: Date?

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: Circle())
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
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if touchStart == nil {
                        touchStart = Date()
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
                            onRightClick?()
                        } else {
                            onTap?()
                        }
                    }
                }
        )
        .accessibilityLabel("Relative pointer")
        .accessibilityHint("Drag to nudge the cursor, tap for left click, hold for right click")
    }

    // At most 30 send calls per second; everything between goes into `pendingDx/pendingDy`
    // and is flushed as one accumulated delta when the gate opens. The CommandCoalescer in
    // the transport also accumulates, but throttling earlier reduces message construction
    // and serialisation overhead on 120 Hz ProMotion displays.
    private static let sendHz: TimeInterval = 1.0 / 30

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

        let elapsed = lastEmit.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard elapsed >= Self.sendHz else { return }
        lastEmit = now

        let toSend = CGSize(width: pendingDx, height: pendingDy)
        pendingDx = 0
        pendingDy = 0
        guard toSend.width != 0 || toSend.height != 0 else { return }
        onMove(toSend)
    }
}

/// The visual half of a rail button.
///
/// Split out because the `Menu`s that sit in a rail take a label rather than a button as their
/// content, and a menu that did not match the buttons beside it would read as a different kind
/// of control. Built from one view, the two cannot disagree.
/// A fixed width for rail buttons, set by a row that has to divide evenly.
///
/// An environment value rather than a parameter, because the buttons in the portrait dock are
/// separate computed properties and one of them — Desktops — a `@ViewBuilder` may not produce at
/// all. Threading a width through all of them would still leave that case applying a width to a
/// view that is not there, which in an `HStack` is a gap the width of a button. Set on the row,
/// it reaches every button that exists and nothing else.
private struct RailButtonWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var railButtonWidth: CGFloat? {
        get { self[RailButtonWidthKey.self] }
        set { self[RailButtonWidthKey.self] = newValue }
    }
}

struct RailButtonLabel: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var enabled: Bool = true

    /// Set by a row of buttons that have to be the same width as each other. Nil fills whatever
    /// the button is given, which is what a rail wants.
    @Environment(\.railButtonWidth) private var fixedWidth: CGFloat?

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
        .frame(width: fixedWidth)
        .frame(minWidth: Self.minimumWidth, maxWidth: fixedWidth == nil ? .infinity : nil)
        .frame(height: ChromeMetrics.buttonHeight)
        // A stadium, like the rail it sits in. A 10pt corner inside a capsule is a shape borrowed
        // from somewhere else — the rail's ends and the button's ends are the only two curves on
        // screen and they have to be the same curve. In the rail, where a button is as wide as it
        // is tall, this makes it a circle.
        .background(selected ? ColorPalette.selectedFill : Color.clear, in: Capsule())
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
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(RailButtonStyle())
        .accessibilityLabel(label)
    }
}

/// The press feedback every control in a rail shares.
///
/// A `.plain` button on iOS gives no sign it was hit at all, which on a translucent panel over
/// live video makes a tap feel like it did nothing — the worst possible outcome for a control
/// whose whole job is sending an event to another machine, where the result is not on this
/// screen to be seen.
struct RailButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
        .buttonStyle(RailButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
        .glassEffect(.regular, in: Capsule())
        // Clipped to that same capsule, and this is not the same thing as shaping the glass.
        // `glassEffect(in:)` only draws the background in a capsule; the content is still bounded
        // by the rail's *rectangle*, so a button scrolling past the end of a short rail shows
        // through the transparent curve beside it and the caption appears to float outside its own
        // panel. The padding above keeps buttons clear of the curve at rest; this is what keeps
        // them clear while they move through it.
        .clipShape(Capsule())
    }
}

/// A track you drag to scroll the Mac.
///
/// The two-finger gesture is the shortcut, but it takes the second hand off the phone and cannot
/// be done one-handed at all — which is how a phone is usually held. This is the same action as
/// something the thumb already holding the device can reach.
struct ScrollWheelView: View {
    /// Pixels to scroll, signed the way a two-finger drag is: positive is downward.
    var onScroll: (CGFloat) -> Void

    /// What this wheel does at the moment — scrolling the Mac or resizing the picture. Only ever
    /// spoken, and only because the same control means two different things depending on the mode
    /// the user chose: a control whose name is fixed while its job is not is a control that lies
    /// to whoever is listening rather than looking.
    var label: String = "Scroll the Mac"

    /// Where this control's value sits, 0 at the bottom of the track and 1 at the top.
    ///
    /// Nil when the wheel has no value to show — scrolling the Mac has no position to report, so
    /// the knob tracks the drag and springs back. Set, it becomes a gauge and the knob is replaced
    /// by a fill up to this point.
    var position: CGFloat?

    /// A point of finger travel is several pixels of scroll. The track is short and has to cover
    /// a whole page, so one-to-one would feel stuck.
    private static let pixelsPerPoint: CGFloat = 6
    /// How far the knob may travel from the centre while being dragged.
    private static let knobTravel: CGFloat = 18

    @State private var isDragging = false
    @State private var lastOffset: CGFloat?
    @State private var knob: CGFloat = 0

    var body: some View {
        VStack(spacing: ChromeMetrics.buttonGap) {
            chevron("chevron.up", step: -90)

            ZStack {
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                            .frame(width: 10)

                        if let position {
                            // A gauge, not a knob. In drag & zoom this control has a *value* to
                            // report — how much of the zoom range lies below and how much above —
                            // and a handle that springs back to the middle reports nothing at
                            // all, which is exactly what made it confusing. A fill rising from
                            // the bottom is the one shape that reads as "this much, out of that
                            // much" without having to be learned.
                            Capsule()
                                .fill(ColorPalette.accent)
                                .frame(width: 10, height: max(10, proxy.size.height * position))
                                .animation(Motion.tap, value: position)
                        } else {
                            // The knob tracks the *drag*, not a scroll position. This control has
                            // no idea where the Mac's document is, and a knob that claimed to
                            // would start lying the moment anything else — a trackpad, an app, a
                            // page load — moved it.
                            Capsule()
                                .fill(.white.opacity(isDragging ? 0.95 : 0.55))
                                .frame(width: 10, height: 34)
                                .offset(y: knob)
                                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: knob)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The whole panel is the drag target, not just the track. A 10pt-wide strip is not
            // something a thumb can reliably find while holding a phone one-handed.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let y = value.location.y
                        defer { lastOffset = y }
                        guard let previous = lastOffset else {
                            isDragging = true
                            return
                        }
                        let delta = y - previous
                        guard delta != 0 else { return }
                        isDragging = true
                        knob = min(max(knob + delta, -Self.knobTravel), Self.knobTravel)
                        onScroll(delta * Self.pixelsPerPoint)
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastOffset = nil
                        knob = 0
                    }
            )
            .accessibilityLabel(label)
            .accessibilityHint("Drag up or down")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onScroll(-120)
                case .decrement: onScroll(120)
                @unknown default: break
                }
            }

            chevron("chevron.down", step: 90)
        }
        .padding(.vertical, ChromeMetrics.panelPadding)
        .frame(width: ChromeMetrics.panelWidth, height: ChromeMetrics.wheelHeight)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous)
        )
    }

    private func chevron(_ symbol: String, step: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { onScroll(step) }
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
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
    var macros: [Macro] = Macro.defaults

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(macros) { macro in
                    Button {
                        model.run(macro)
                    } label: {
                        Text(macro.title)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// An application's icon: the PNG the host rendered, or a symbol when it sent none.
///
/// Shared rather than private to the picker, because the source list and the settings panel both
/// draw rows of them.
struct ApplicationIcon: View {
    let data: Data?
    let fallback: String

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(width: 42, height: 42)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

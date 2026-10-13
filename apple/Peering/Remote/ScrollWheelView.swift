import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

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
    @State private var lastDetentAt: MonotonicStamp?
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

        let started = MonotonicStamp()
        let duration = WheelSpin.duration(launch)
        spinTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.spinHz))
                // A cancelled sleep returns at once, and without this the loop would emit one more
                // roll after the wheel had been caught.
                guard !Task.isCancelled else { return }
                let elapsed = started.elapsedSeconds()
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
        if spinning, let last = lastDetentAt, last.isWithin(seconds: Self.detentInterval) {
            return
        }
        lastDetentAt = MonotonicStamp()
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

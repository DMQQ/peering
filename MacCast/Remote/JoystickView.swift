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

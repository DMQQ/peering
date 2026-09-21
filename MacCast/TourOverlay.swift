import MacCastKit
import SwiftUI

/// Where the control a tour is describing actually is.
///
/// **Read from the view, never from a table of rectangles.** A hardcoded rectangle is right on the
/// phone it was measured on and wrong on every other one, wrong in the other orientation, and wrong
/// again the moment a card above it changes height, which on these screens happens every time
/// something is paired or a shell is opened. So each control reports its own frame and this is the
/// pipe it travels up.
///
/// A `PreferenceKey` rather than a binding written from a geometry callback, because the two
/// answer different questions. A binding says where a view *is*; a preference says what is on the
/// screen *now*, and the second is what a tour needs: a view that has gone reports nothing, so the
/// dictionary it collects is exactly the set of controls the person can currently see, and a step
/// for a control that is not in it is dropped before anything is drawn. That includes the cases
/// that have nothing to do with layout: a control that only exists once connected, a panel that is
/// collapsed, a card that is only drawn while something is open.
///
/// `Anchor` rather than `CGRect`, so the rectangle is resolved in the coordinate space of whoever
/// reads the preference. A frame read in the global space and compared against a local one is a
/// ring drawn somewhere near the control on a good day and off the screen on a bad one; an anchor
/// carries its own space with it.
private struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]

    /// Merged rather than replaced, because every control in a tour contributes to one dictionary.
    /// Last wins for a target reported twice, which is deliberate: a tour that names two controls
    /// as one step (the dock and the rails, say) means whichever of them is on screen.
    static func reduce(
        value: inout [TourTarget: Anchor<CGRect>],
        nextValue: () -> [TourTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, reported in reported }
    }
}

extension View {
    /// Says that this view is the control a step of this name is about.
    ///
    /// Applied to the control itself rather than to a wrapper around it, so what is highlighted is
    /// the thing being described and not the space it happens to sit in. On a row, that means the
    /// row; inside a scroller, the chip.
    func tourAnchor(_ target: TourTarget) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

// MARK: - Hosting

extension View {
    /// Runs the first-run tours this screen owes, over the screen.
    ///
    /// Takes the tours that are *due* rather than the flags themselves: what is owed changes as the
    /// screen changes (the Connect header's cards have to have arrived, the remote screen's hint has
    /// to have gone), and that decision belongs to the screen, which knows what state it is in.
    /// This only knows how to show them.
    ///
    /// The list is also the queue. A screen that owes two tours shows them in the order given, one
    /// after the other, and never two at once: two dimmed layers with two cards is not twice the
    /// explanation, it is a screen nobody can read.
    func firstRunTours(
        _ dueTours: [Tour],
        onDismiss: @escaping (Tour) -> Void
    ) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                // Both halves of "is this on screen": a control that is not drawn reports nothing
                // at all, and one that is drawn but scrolled out of sight reports a rectangle
                // outside these bounds. Neither is a thing to draw a ring around.
                let rects = anchors.compactMapValues { anchor -> CGRect? in
                    let rect = proxy[anchor]
                    return TourVisibility.isOnScreen(rect, in: bounds) ? rect : nil
                }
                TourLayer(dueTours: dueTours, bounds: bounds, rects: rects, onDismiss: onDismiss)
            }
        }
    }
}

/// The tour as it is running: which step is up, and what the screen is doing underneath it.
///
/// Stateful on purpose, and this is the only place that is. The rest of the feature is a script and
/// two rectangles of arithmetic; what lives here is the difference between a tour that has been
/// started, one that has been finished and one that has been turned down, which is exactly the
/// state ``Tour`` persists per screen.
private struct TourLayer: View {
    let dueTours: [Tour]
    let bounds: CGRect
    let rects: [TourTarget: CGRect]
    let onDismiss: (Tour) -> Void

    @State private var run: TourRun?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let run, let step = run.current, let hole = rects[step.target] {
                TourCoach(
                    step: step,
                    number: run.number,
                    count: run.count,
                    hole: hole,
                    bounds: bounds,
                    onNext: advance,
                    onSkip: skip
                )
            }
        }
        // The ring travels between steps rather than being redrawn in the next place. A tour is a
        // sequence of things in one screen, and a highlight that jumps is a highlight the eye has
        // to find again on every tap.
        .animation(Motion.settle, value: run?.current?.target)
        // `initial: true`, because a screen reached for the first time is already in the state
        // that owes the tour, and a plain `onChange` would sit there waiting for a flag to change
        // under a person who has never seen the screen before.
        .onChange(of: dueTours, initial: true) { _, _ in startIfIdle() }
        // The screen arriving is what brings the controls, and a tour whose targets are still
        // being laid out has nothing to point at yet. Every pass is a chance to start.
        .onChange(of: rects) { _, _ in reconcileOrStart() }
    }

    // MARK: Moving through a tour

    /// Starts the first tour that is owed and can be shown, if nothing is running.
    ///
    /// A tour with none of its controls on screen is not started and not marked as seen: it is
    /// still owed, and it is owed to somebody who has not read it. The queue moves on to the next
    /// one, which is what lets a screen list two tours and have the second follow the first.
    private func startIfIdle() {
        guard run == nil else { return }
        let appearing = Set(rects.keys)
        for tour in dueTours {
            guard let started = TourRun(tour: tour, appearing: appearing) else { continue }
            withAnimation(Motion.settle) { run = started }
            return
        }
    }

    /// A pass of the screen while a tour is up: keep the step, or move past one that has gone.
    private func reconcileOrStart() {
        guard var current = run else {
            startIfIdle()
            return
        }
        current.skipMissing(appearing: Set(rects.keys))
        guard current.current != nil else {
            // Everything left in the tour has gone from the screen. It is *not* marked as seen:
            // the person has neither finished it nor turned it down, and a tour left unread
            // because a panel closed is a tour they are still owed.
            withAnimation(Motion.settle) { run = nil }
            return
        }
        if current != run { run = current }
    }

    private func advance() {
        guard var current = run else { return }
        current.advance()
        if current.isFinished {
            end(current.tour)
        } else {
            run = current
        }
    }

    private func skip() {
        guard let current = run else { return }
        end(current.tour)
    }

    /// Both exits, which are the same instruction: this tour has been answered.
    ///
    /// The flag is written here rather than by the screen, because this is the only place that
    /// knows the difference between a tour that has been read and one that has been abandoned by
    /// the screen changing. See ``TourLayer/reconcileOrStart()``.
    private func end(_ tour: Tour) {
        onDismiss(tour)
        withAnimation(Motion.settle) { run = nil }
    }
}

// MARK: - The tour on screen

/// The dim, the ring, and the card: one step of a tour.
///
/// Everything here is one decision seen from three sides: the app is taken down to a near-black
/// sheet with a single rectangle left out of it, that rectangle is edged in white so it reads as
/// lit rather than as a hole, and the sentence about it is anchored to it by a caret. A ring alone
/// says "this one"; against a dimmed screen at arm's length it says it about as well as pointing
/// does, which is why the dim is the part doing the work.
private struct TourCoach: View {
    let step: TourStep
    let number: Int
    let count: Int
    let hole: CGRect
    let bounds: CGRect
    let onNext: () -> Void
    let onSkip: () -> Void

    /// The card's measured height, which is what the placement needs and the only number here that
    /// cannot be known in advance: the same sentence is two lines on one phone and three on
    /// another, and a card placed from an assumed height covers the control it describes.
    @State private var cardHeight: CGFloat = 0

    /// How far the ring stands off the control it is around.
    ///
    /// Off it rather than on it. A ring drawn tight around a control covers its own edge, and a
    /// highlighted button that has lost its outline reads as a different button. Six points also
    /// clears the plan badges that hang off the corner of a gated control.
    private static let ringInset: CGFloat = 6
    private static let ringRadius: CGFloat = 18
    private static let caretWidth: CGFloat = 22
    private static let caretHeight: CGFloat = 9
    /// How far the dim is extended past the screen on every side.
    ///
    /// **The dim has to cover the status bar and the tab bar, and the tour is hosted inside a
    /// screen that stops short of both.** A dim that ended at the screen's own frame would leave a
    /// lit band above and below the very thing it is trying to take out of the picture, and the
    /// bands are exactly where the screen usually has something. Four hundred points is past every
    /// safe area on any phone this runs on, and it is added to the *drawing* rather than by
    /// `ignoresSafeArea`, which would move the origin the highlighted rectangle is measured
    /// against and put the ring somewhere else entirely.
    private static let overshoot: CGFloat = 400

    private var cardWidth: CGFloat { TourCallout.cardWidth(in: bounds.size) }

    private var ring: CGRect {
        hole.insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
    }

    private var placement: TourCallout {
        TourCallout.placement(
            hole: ring,
            cardSize: CGSize(width: cardWidth, height: cardHeight),
            in: bounds.size,
            // Far enough that the caret's point lands clear of the ring, and no further: the card
            // is meant to look attached to the control, and a gap wide enough to read as a separate
            // object is how a tooltip stops being about anything.
            gap: Self.ringInset + Self.caretHeight + 6
        )
    }

    var body: some View {
        let placement = placement

        return ZStack(alignment: .topLeading) {
            dim(ring: ring)

            RoundedRectangle(cornerRadius: Self.ringRadius, style: .continuous)
                // White rather than the accent, and the accent is what it was. In this app blue
                // means one thing ("this one is on"), and a ring around a control is not saying
                // the control is on, it is saying *look here*: the same sentence the card is
                // making, in the same white the card is drawn in. A blue ring also reads as part
                // of the app underneath, which is a control that has been selected rather than
                // one being pointed at.
                .strokeBorder(ColorPalette.ink, lineWidth: 2)
                .frame(width: ring.width, height: ring.height)
                .shadow(color: ColorPalette.ink.opacity(0.45), radius: 12)
                .position(x: ring.midX, y: ring.midY)
                .allowsHitTesting(false)

            card(placement: placement)
                // Snap internal layout when the step changes so the button does not animate
                // on two simultaneous springs: one for the card's position and a second for
                // its VStack layout reflowing. The position spring (from the parent ZStack's
                // implicit animation) is applied outside this scope and still runs.
                .animation(nil, value: step.id)
                .position(x: placement.frame.midX, y: placement.frame.midY)
        }
    }

    /// Everything except the control, in the app's own near-black.
    ///
    /// Even-odd filled rather than a mask or a blend mode, and that is a decision about what is
    /// left on screen. The hole is a *rounded* rectangle: punched with a blend mode, the corners of
    /// a rounded hole are the one part of this that varies with the compositing underneath, and the
    /// screen underneath is a live Mac desktop, a terminal, or a card list. One path with two
    /// subpaths paints the same shape over anything.
    private func dim(ring: CGRect) -> some View {
        SpotlightShape(
            hole: ring.offsetBy(dx: Self.overshoot, dy: Self.overshoot),
            cornerRadius: Self.ringRadius
        )
        .fill(ColorPalette.backdrop.opacity(0.84), style: FillStyle(eoFill: true))
        .frame(
            width: bounds.width + Self.overshoot * 2,
            height: bounds.height + Self.overshoot * 2
        )
        // The outer frame is what keeps the drawing aligned: the oversized shape is centred on the
        // screen's own rectangle, so a point at the screen's origin is a point at `overshoot` inside
        // the shape. That is the same trick the ring uses below, and the reason the two agree.
        .frame(width: bounds.width, height: bounds.height)
        .contentShape(Rectangle())
        // **Anywhere on the dim moves the tour on, and this is the way out of it.** The card has
        // its own two buttons, but a tour that dimmed the whole screen and offered a single
        // target to press would be a tour that has covered the only control that leaves the
        // screen. There is no state in which this is not tappable, so there is no state in which
        // the person is stuck in one.
        .onTapGesture(perform: onNext)
        .accessibilityLabel("\(step.title). \(step.detail)")
        .accessibilityHint("Double tap to continue. Tip \(number) of \(count).")
        .accessibilityAddTraits(.isButton)
    }

    /// The sentence, its caret, and the two ways on.
    private func card(placement: TourCallout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)
                Spacer(minLength: 8)
                // Where this is in the tour, which is the one thing a coach mark cannot say for
                // itself: a person who does not know whether there are three of these or nine has
                // no way to decide whether to spend the time.
                Text("\(number) of \(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(step.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)

            HStack(spacing: 12) {
                Button("Skip", action: onSkip)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button(action: onNext) {
                    Text(number == count ? "Done" : "Next")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(ColorPalette.ink, in: Capsule())
                        .foregroundStyle(ColorPalette.onInk)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: cardWidth, alignment: .leading)
        .background {
            TourCalloutShape(
                edge: placement.caretEdge,
                caretX: placement.caretX,
                caretWidth: Self.caretWidth,
                caretHeight: Self.caretHeight
            )
            .fill(ColorPalette.backdrop.opacity(0.97))
        }
        .overlay {
            // The same hairline every raised surface in the app wears, so the card reads as one of
            // the app's own panels rather than as a sheet that arrived from the system.
            TourCalloutShape(
                edge: placement.caretEdge,
                caretX: placement.caretX,
                caretWidth: Self.caretWidth,
                caretHeight: Self.caretHeight
            )
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.22), .white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard height > 0, height != cardHeight else { return }
            cardHeight = height
        }
        // A tap on the card's own surface is a tap on the card, not on the dim behind it: without
        // this, the gap between two lines of the sentence would advance the tour.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shapes

/// The dim: everything, less a rounded rectangle.
///
/// One path with the screen's rectangle and the hole in it, filled even-odd. See
/// ``TourCoach/dim(ring:)`` for why this is not a mask.
private nonisolated struct SpotlightShape: Shape {
    let hole: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}

/// The card's shape: a rounded rectangle with the caret as part of the same outline.
///
/// **One outline rather than a card with a triangle behind it.** Two shapes stacked would have two
/// edges between them, and the card's own hairline would run straight across the base of its caret
/// a line through the one mark that says which control the sentence is about. Drawn as a single
/// closed path there is no edge to stumble over, and the stroke follows the caret out and back.
///
/// `InsettableShape` because that is what `strokeBorder` needs, and `strokeBorder` is what keeps
/// the hairline inside the shape instead of straddling it: a border centred on the edge is half a
/// point wider than the card on every side, which is visible on a shape this dark.
private nonisolated struct TourCalloutShape: InsettableShape {
    let edge: TourCallout.Edge
    let caretX: CGFloat
    var caretWidth: CGFloat
    var caretHeight: CGFloat
    var cornerRadius: CGFloat = 20
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > cornerRadius * 2, r.height > cornerRadius * 2 else { return Path() }

        let radius = cornerRadius
        // The caret stays on the flat part of the edge. One hanging off a corner would have no
        // edge to sit on, and the card is placed so this is nearly always a no-op.
        let lowest = r.minX + radius + caretWidth / 2
        let highest = r.maxX - radius - caretWidth / 2
        let mid = lowest <= highest ? min(max(caretX, lowest), highest) : r.midX

        var path = Path()
        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        if edge == .below {
            path.addLine(to: CGPoint(x: mid - caretWidth / 2, y: r.minY))
            path.addLine(to: CGPoint(x: mid, y: r.minY - caretHeight))
            path.addLine(to: CGPoint(x: mid + caretWidth / 2, y: r.minY))
        }
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(
            tangent1End: CGPoint(x: r.maxX, y: r.minY),
            tangent2End: CGPoint(x: r.maxX, y: r.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        // **The bottom-right corner, which was missing and is the whole of what went wrong with
        // this outline.** Without it the path ran from the right edge straight to the caret's near
        // edge, which drew the card as though its lower right had been sliced off at an angle, and
        // sliced differently on the two edges because only one of them has a caret to run into. It
        // is the same arc as the other three, and it has to be added before the caret rather than
        // after: the caret sits on the flat part of the edge, and the corner is what ends it.
        path.addArc(
            tangent1End: CGPoint(x: r.maxX, y: r.maxY),
            tangent2End: CGPoint(x: r.minX, y: r.maxY),
            radius: radius
        )
        if edge == .above {
            path.addLine(to: CGPoint(x: mid + caretWidth / 2, y: r.maxY))
            path.addLine(to: CGPoint(x: mid, y: r.maxY + caretHeight))
            path.addLine(to: CGPoint(x: mid - caretWidth / 2, y: r.maxY))
        }
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addArc(
            tangent1End: CGPoint(x: r.minX, y: r.maxY),
            tangent2End: CGPoint(x: r.minX, y: r.minY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: r.minX, y: r.minY),
            tangent2End: CGPoint(x: r.minX + radius, y: r.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack(alignment: .topLeading) {
        AppBackdrop()
        VStack(spacing: 20) {
            Text("Peering").font(.largeTitle)
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.1)).frame(height: 80)
        }
        .padding(24)
        .tourAnchor(.connectNearby)
    }
    .firstRunTours([.connect]) { _ in }
    .preferredColorScheme(.dark)
}

import MacCastKit
import SwiftUI

/// Where the control a tour describes is, read from the view rather than a table of rectangles (wrong on other phones, orientations and card heights).
/// A `PreferenceKey`, not a binding: a view that has gone reports nothing, so the dictionary is exactly the controls now visible and steps for absent ones are dropped.
/// `Anchor` rather than `CGRect`, so the rectangle resolves in the reader's coordinate space.
/// `Anchor` rather than `CGRect`, so the rectangle is resolved in the coordinate space of whoever
private struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]

    /// Merged, one dictionary for the whole tour. Last wins for a target reported twice, deliberately: a step naming two controls (the dock and the rails) means whichever is on screen.
    static func reduce(
        value: inout [TourTarget: Anchor<CGRect>],
        nextValue: () -> [TourTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, reported in reported }
    }
}

extension View {
    func tourAnchor(_ target: TourTarget) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

// MARK: - Hosting

extension View {
    /// Shows the tours that are due, in the order given and never two at once. What is owed is the screen's decision.
    func firstRunTours(
        _ dueTours: [Tour],
        onDismiss: @escaping (Tour) -> Void
    ) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                // Both halves of on screen: a control not drawn reports nothing, one scrolled out of sight reports a rect outside the bounds.
                let rects = anchors.compactMapValues { anchor -> CGRect? in
                    let rect = proxy[anchor]
                    return TourVisibility.isOnScreen(rect, in: bounds) ? rect : nil
                }
                TourLayer(dueTours: dueTours, bounds: bounds, rects: rects, onDismiss: onDismiss)
            }
        }
    }
}

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
        // The ring travels between steps rather than jumping.
        .animation(Motion.settle, value: run?.current?.target)
        // `initial: true`: a screen reached for the first time already owes the tour, and a plain `onChange` would wait for a flag change.
        .onChange(of: dueTours, initial: true) { _, _ in startIfIdle() }
        // The screen arriving brings the controls, so every pass is a chance to start.
        .onChange(of: rects) { _, _ in reconcileOrStart() }
    }

    // MARK: Moving through a tour

    /// A tour with none of its controls on screen is not started or marked seen: it is still owed. The queue moves on to the next.
    private func startIfIdle() {
        guard run == nil else { return }
        let appearing = Set(rects.keys)
        for tour in dueTours {
            guard let started = TourRun(tour: tour, appearing: appearing) else { continue }
            withAnimation(Motion.settle) { run = started }
            return
        }
    }

    private func reconcileOrStart() {
        guard var current = run else {
            startIfIdle()
            return
        }
        current.skipMissing(appearing: Set(rects.keys))
        guard current.current != nil else {
            // Not marked as seen: the person neither finished nor turned it down, so it is still owed.
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

    /// The flag is written here because only this knows a tour read from one abandoned by the screen changing. See ``TourLayer/reconcileOrStart()``.
    private func end(_ tour: Tour) {
        onDismiss(tour)
        withAnimation(Motion.settle) { run = nil }
    }
}

// MARK: - The tour on screen

private struct TourCoach: View {
    let step: TourStep
    let number: Int
    let count: Int
    let hole: CGRect
    let bounds: CGRect
    let onNext: () -> Void
    let onSkip: () -> Void

    /// The card's measured height: the same sentence is two or three lines depending on phone, and an assumed height covers the control.
    @State private var cardHeight: CGFloat = 0

    /// Off the control, not on it: a tight ring covers its edge, and six points clears plan badges on a gated control.
    private static let ringInset: CGFloat = 6
    private static let ringRadius: CGFloat = 18
    private static let caretWidth: CGFloat = 22
    private static let caretHeight: CGFloat = 9
    /// The dim has to cover the status bar and tab bar, which the hosting screen stops short of. Added to the drawing, not via `ignoresSafeArea`, which would move the origin the ring is measured against.
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
            // Far enough that the caret clears the ring and no further, so the card still reads as attached.
            gap: Self.ringInset + Self.caretHeight + 6
        )
    }

    var body: some View {
        let placement = placement

        return ZStack(alignment: .topLeading) {
            dim(ring: ring)

            RoundedRectangle(cornerRadius: Self.ringRadius, style: .continuous)
                // White rather than the accent: blue means on in this app, and a ring says look here.
                .strokeBorder(ColorPalette.ink, lineWidth: 2)
                .frame(width: ring.width, height: ring.height)
                .shadow(color: ColorPalette.ink.opacity(0.45), radius: 12)
                .position(x: ring.midX, y: ring.midY)
                .allowsHitTesting(false)

            card(placement: placement)
                // Snap internal layout on step change so the button is not on two simultaneous springs; the position spring runs outside this scope.
                .animation(nil, value: step.id)
                .position(x: placement.frame.midX, y: placement.frame.midY)
        }
    }

    /// Even-odd filled rather than a mask or blend mode: blend-mode corners of a rounded hole vary with the compositing underneath.
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
        // The oversized shape is centred on the screen's rectangle, so the screen's origin is `overshoot` inside it; the ring relies on the same.
        .frame(width: bounds.width, height: bounds.height)
        .contentShape(Rectangle())
        // Anywhere on the dim moves the tour on: it covers the screen, so it must also be the way out.
        .onTapGesture(perform: onNext)
        .accessibilityLabel("\(step.title). \(step.detail)")
        .accessibilityHint("Double tap to continue. Tip \(number) of \(count).")
        .accessibilityAddTraits(.isButton)
    }

    private func card(placement: TourCallout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)
                Spacer(minLength: 8)
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

/// One outline rather than a card with a triangle behind it: two shapes would draw the hairline across the caret's base. `InsettableShape` so `strokeBorder` keeps the hairline inside.
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
        // The caret stays on the flat part of the edge; one at a corner would have no edge to sit on.
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
        // The bottom-right corner must be added before the caret: without it the path sliced the card's lower right at an angle.
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

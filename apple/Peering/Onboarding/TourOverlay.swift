import PeeringKit
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

// MARK: - Shapes

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

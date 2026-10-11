import SwiftUI

struct FloatingChip: Identifiable {
    let symbol: String
    let title: String
    let alignment: HorizontalAlignment
    /// A fraction of the field's height, measured to the chip's top edge.
    let y: Double

    var id: String { symbol }
}

/// Glass chips hung on the edges of whatever is under them, each drifting on its own phase. Drawn as a layer the size of its parent, so it takes the box and never the layout.
struct FloatingChips: View {
    let chips: [FloatingChip]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack(alignment: .top) {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                        chipView(chip)
                            .scaleEffect(arrived ? 1 : 0.8)
                            .opacity(arrived ? 1 : 0)
                            .offset(y: arrived ? 0 : 14)
                            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72).delay(0.12 + Double(index) * 0.09), value: arrived)
                            .offset(y: reduceMotion ? 0 : sin(time * 0.9 + Double(index) * 2) * 4)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: chip.alignment, vertical: .center))
                            .padding(.top, proxy.size.height * chip.y)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        // The tour slides in under `withAnimation`, and the field's box grows from nothing during that transaction: left alone, every chip travels in from the corner. Layout is not animated; the pop-in below carries its own animation.
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // One frame at the starting value first: flipping it in the same update animates from itself.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            arrived = true
        }
    }

    private func chipView(_ chip: FloatingChip) -> some View {
        Label(chip.title, systemImage: chip.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ColorPalette.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassSurface(in: Capsule())
    }
}
